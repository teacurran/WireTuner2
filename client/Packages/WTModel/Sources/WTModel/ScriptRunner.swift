import Foundation
import Synchronization
import WTCRDT

// DATA-011/015: running scripts.  `ScriptRunner` runs a whole script on a document (the Script
// Editor's btn:[Run], the Scripts menu); `ScriptTransformer` runs field transforms for a record
// set; `ScriptRecordSource` runs a script source's `records` export.  Nothing runs on its own:
// every entry point is called from a user action.

/// What a run did.
public struct ScriptRunResult: Sendable {
    /// Why it stopped early (nil: it ran to the end).
    public var error: ScriptError?
    public var console: [ScriptConsoleEntry]
    /// How many document changes it emitted.
    public var changes: Int
    /// The hosts `wt.fetch` reached (*Show Hosts* for script sources).
    public var hosts: [String]
}

/// Runs a script on a document (scripting.adoc, "Running a script").  Property sets are changes
/// labelled `Script: <name>`; `wt.document.transaction` makes one undo step.  `stop()` (btn:[Stop],
/// the progress sheet's btn:[Cancel]) stops after the current statement; what the script already
/// did stays and can be undone.
public final class ScriptRunner: @unchecked Sendable {
    public let limits: ScriptLimits
    private let running = Mutex<ScriptContext?>(nil)
    private let stopRequested = Mutex(false)

    public init(limits: ScriptLimits = .standard) {
        self.limits = limits
    }

    /// Runs `source` named `name` on `target` on the calling thread (never the main thread when
    /// the target is a `DocumentScriptTarget`).  `records` and `current` feed `wt.records`;
    /// `console` receives each console line as it is written.
    public func run(_ source: String, name: String, target: any ScriptTarget, host: (any ScriptHost)? = nil, fetcher: (any ScriptFetching)? = nil,
                    records: RecordSet? = nil, current: Int = 0, console: (@Sendable (ScriptConsoleEntry) -> Void)? = nil) -> ScriptRunResult {
        let context = ScriptContext(name: name, limits: limits)
        context.onConsole = console
        running.withLock { $0 = context }
        if stopRequested.withLock({ $0 }) { context.stop() }
        defer { running.withLock { $0 = nil } }
        let writer = ScriptWriter(target: target, label: "Script: \(name)")
        let environment = ScriptEnvironment(context: context, writer: writer, host: host, fetcher: fetcher, records: records, current: current)
        var failure: ScriptError?
        do {
            try context.load(source)
        } catch let error as ScriptError {
            failure = error
        } catch {
            failure = .exception(message: String(describing: error), line: nil, column: nil)
        }
        writer.abandon()
        if let failure { context.log(.error, failure.description) }
        return ScriptRunResult(error: failure, console: context.console, changes: writer.changes, hosts: environment.fetchedHosts)
    }

    /// `run` on a thread of its own, awaited: the way the window runs a script so the main actor
    /// stays free to perform its changes.
    public func runDetached(_ source: String, name: String, target: any ScriptTarget, host: (any ScriptHost)? = nil,
                            fetcher: (any ScriptFetching)? = nil, records: RecordSet? = nil, current: Int = 0,
                            console: (@Sendable (ScriptConsoleEntry) -> Void)? = nil) async -> ScriptRunResult {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: self.run(source, name: name, target: target, host: host, fetcher: fetcher, records: records,
                                                        current: current, console: console))
            }
            thread.name = "WireTuner script: \(name)"
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    /// Stops the running script (or the next one to start, if called before it does).
    public func stop() {
        stopRequested.withLock { $0 = true }
        running.withLock { $0?.stop() }
    }
}

/// Field transforms through the runtime (data-merge.adoc, "Transforming a field with a script";
/// DATA-015): one context per transform script for the whole record set, the `transform` export
/// called per record under the wall-clock limit.  A transform that throws reports the record
/// and leaves the raw value; one that runs past the limit is stopped, reported, and its context
/// replaced.
public final class ScriptTransformer: FieldTransforming, @unchecked Sendable {
    private let state: EngineState
    private let limits: ScriptLimits
    private let fetcher: (any ScriptFetching)?
    private var contexts: [OpID: ScriptContext] = [:]

    /// Transforms reading scripts from `state`; `limits.wallClock` is per record.
    public init(state: EngineState, limits: ScriptLimits = .standard, fetcher: (any ScriptFetching)? = nil) {
        self.state = state
        self.limits = limits
        self.fetcher = fetcher
    }

    private func context(_ script: OpID) throws -> ScriptContext {
        if let existing = contexts[script] { return existing }
        guard let stored = DocumentScript.script(script, in: state) else { throw ScriptError.missingExport("transform") }
        let context = ScriptContext(name: stored.name, limits: limits)
        let writer = ScriptWriter(target: ReadOnlyScriptTarget(state), label: "Script: \(stored.name)")
        _ = ScriptEnvironment(context: context, writer: writer, host: nil, fetcher: fetcher, records: nil, current: 0)
        try context.load(stored.source)
        contexts[script] = context
        return context
    }

    public func transform(script: OpID, value: String?, record: [String: String], field: String) throws -> String? {
        let context = try context(script)
        context.watchdog.progressed()
        do {
            let result = try context.call("transform", [value.map { $0 as Any } ?? NSNull(), record, field])
            switch result {
            case nil: return nil
            case let text as String: return text
            case let number as NSNumber: return number.stringValue
            default: return DataTable.jsonText(result!)
            }
        } catch ScriptError.timeout {
            contexts[script] = nil
            throw ScriptError.timeout
        }
    }
}

/// A script source (data-merge.adoc, "A script"): the `records(params)` export of a document
/// script, run once per refresh; each returned object is a record whose properties are
/// columns (nested values as compact JSON).
public enum ScriptRecordSource {
    /// What a refresh returns: the records and the hosts `wt.fetch` reached.
    public struct Result: Sendable {
        public var table: DataTable
        public var hosts: [String]
        public var console: [ScriptConsoleEntry]
    }

    public static func records(script: OpID, state: EngineState, params: [String: String] = [:], fetcher: (any ScriptFetching)? = nil,
                               limits: ScriptLimits = .standard) throws -> Result {
        guard let stored = DocumentScript.script(script, in: state) else { throw ScriptError.missingExport("records") }
        let context = ScriptContext(name: stored.name, limits: limits)
        let writer = ScriptWriter(target: ReadOnlyScriptTarget(state), label: "Script: \(stored.name)")
        let environment = ScriptEnvironment(context: context, writer: writer, host: nil, fetcher: fetcher, records: nil, current: 0)
        try context.load(stored.source)
        let value = try context.call("records", [params])
        guard let rows = value as? [Any] else { throw ScriptError.exception(message: "records() must return an array of objects", line: nil, column: nil) }
        var columns: [String] = []
        var seen: Set<String> = []
        var records: [DataRecord] = []
        for row in rows {
            guard let object = row as? [String: Any] else { throw ScriptError.exception(message: "records() must return an array of objects", line: nil, column: nil) }
            var values: [String: String] = [:]
            for key in object.keys.sorted() {
                if seen.insert(key).inserted { columns.append(key) }
                if let text = DataTable.jsonText(object[key]!) { values[key] = text }
            }
            records.append(DataRecord(values))
        }
        return Result(table: DataTable(columns: columns, records: records), hosts: environment.fetchedHosts, console: context.console)
    }
}

extension DataTable {
    /// A value as record text: strings as they are, numbers and booleans in their JSON form,
    /// null as absent, objects and arrays as compact JSON.
    static func jsonText(_ value: Any) -> String? {
        switch value {
        case is NSNull: return nil
        case let string as String: return string
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default:
            let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
}
