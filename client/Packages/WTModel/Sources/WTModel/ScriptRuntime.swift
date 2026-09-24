import Darwin
import Foundation
import JavaScriptCore
import Synchronization
import WTCRDT

// DATA-011: the JavaScript host (scripting.adoc, "JavaScript runtime").  One `JSContext` per run
// in its own `JSVirtualMachine`, on a dedicated thread; the `wt` object is installed from Swift
// bridges.  The sandbox has no `require`, file, socket, `XMLHttpRequest`, `WebSocket` or `fetch`
// -- network only through `wt.fetch`, which is the server's `DataSourceService.Proxy` -- and a
// `setTimeout` capped at 60 s.  A watchdog stops a script that runs past the wall-clock limit
// between progress updates, grows past the memory limit, or is stopped by the user.

/// Why a script stopped with an error.  The console shows `description`.
public enum ScriptError: Error, Hashable, Sendable, CustomStringConvertible {
    /// Ran past the wall-clock limit without a progress update (`ScriptTimeout`).
    case timeout
    /// Grew past the memory limit (`ScriptMemoryLimit`).
    case memoryLimit
    /// Stopped by btn:[Stop] or the progress sheet's btn:[Cancel].
    case stopped
    /// An uncaught exception, with where it was thrown (1-based line and column of the script).
    case exception(message: String, line: Int?, column: Int?)
    /// A data-merge script lacks the named export (`records`, `transform`).
    case missingExport(String)
    /// `wt.fetch` without a connection (`OfflineError`).
    case offline

    public var description: String {
        switch self {
        case .timeout: "ScriptTimeout: the script ran for too long without showing progress and was stopped"
        case .memoryLimit: "ScriptMemoryLimit: the script used too much memory and was stopped"
        case .stopped: "The script was stopped"
        case .exception(let message, let line, let column):
            line.map { "\(message) (line \($0)\(column.map { ", column \($0)" } ?? ""))" } ?? message
        case .missingExport(let name): "The script does not export a function named \(name)"
        case .offline: "OfflineError: wt.fetch needs a connection to the WireTuner service"
        }
    }
}

/// The limits of one run (scripting.adoc: 256 MiB per virtual machine, 60 s between progress
/// updates; `setTimeout` at most 60 s).
public struct ScriptLimits: Hashable, Sendable {
    public var wallClock: TimeInterval
    public var memory: Int
    public var maxTimeout: TimeInterval

    public static let standard = ScriptLimits(wallClock: 60, memory: 256 * 1024 * 1024, maxTimeout: 60)

    public init(wallClock: TimeInterval, memory: Int, maxTimeout: TimeInterval = 60) {
        self.wallClock = wallClock
        self.memory = memory
        self.maxTimeout = maxTimeout
    }
}

/// One line of the Script Editor's console.
public struct ScriptConsoleEntry: Hashable, Sendable {
    public enum Level: String, Hashable, Sendable {
        case log, warn, error, table, request
    }

    public var level: Level
    public var text: String

    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }
}

/// The source rewritten from module syntax: `export function records`, `export const x = ...`,
/// `export { a, b as c }`, `export default ...` become ordinary declarations inside an async
/// function whose exports are collected into `__exports` at the end.  Line numbers are kept (the
/// wrapper starts on the script's first line).
public enum ScriptModuleSource {
    public static func wrap(_ source: String) -> (code: String, exports: [String]) {
        var exports: [(name: String, value: String)] = []
        var lines: [String] = []
        for line in source.components(separatedBy: "\n") {
            var text = line
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            let indent = String(line.prefix(line.count - trimmed.count))
            if trimmed.hasPrefix("export default ") {
                let rest = trimmed.dropFirst("export default ".count)
                if let name = declaredName(rest) {
                    exports.append(("default", name))
                    text = indent + rest
                } else {
                    text = indent + "__exports.default = " + rest
                }
            } else if trimmed.hasPrefix("export {") {
                let inside = trimmed.dropFirst("export {".count).prefix { $0 != "}" }
                for item in inside.split(separator: ",") {
                    let parts = item.split(separator: " ").filter { !$0.isEmpty }.map(String.init)
                    if parts.count == 3, parts[1] == "as" { exports.append((parts[2], parts[0])) } else if parts.count == 1 { exports.append((parts[0], parts[0])) }
                }
                text = indent + "/* export list */"
            } else if trimmed.hasPrefix("export ") {
                let rest = trimmed.dropFirst("export ".count)
                if let name = declaredName(rest) { exports.append((name, name)) }
                text = indent + rest
            }
            lines.append(text)
        }
        let collect = exports.map { "__exports[\(quote($0.name))] = (typeof \($0.value) !== 'undefined' ? \($0.value) : undefined);" }.joined(separator: " ")
        let code = "globalThis.__exports = {}; globalThis.__run = (async function() {\"use strict\"; " + lines.joined(separator: "\n")
            + "\n;\(collect)\n})();"
        return (code, exports.map(\.name))
    }

    /// The name a declaration introduces: `function f`, `async function f`, `function* f`,
    /// `class C`, `const x`, `let x`, `var x`.
    static func declaredName(_ text: Substring) -> String? {
        var rest = text
        for keyword in ["async ", "function* ", "function ", "class ", "const ", "let ", "var "] where rest.hasPrefix(keyword) {
            rest = rest.dropFirst(keyword.count)
            if keyword == "async " {
                return declaredName(rest)
            }
            let name = rest.drop { $0 == " " || $0 == "*" }.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "$" }
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    static func quote(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// The watchdog: polled by JavaScriptCore's execution time limit every 50 ms while script code
/// runs, it decides whether to stop the script.
final class ScriptWatchdog: @unchecked Sendable {
    private let state = Mutex<(progress: Date, stopped: Bool, reason: ScriptError?, native: Int)>((Date(), false, nil, 0))
    let limits: ScriptLimits
    let baseline: Int

    init(limits: ScriptLimits) {
        self.limits = limits
        baseline = Self.footprint()
    }

    /// A progress update (`wt.ui.progress(...).update`): the wall clock starts again.
    func progressed() {
        state.withLock { $0.progress = Date() }
    }

    func stop() {
        state.withLock {
            $0.stopped = true
            if $0.reason == nil { $0.reason = .stopped }
        }
    }

    var reason: ScriptError? { state.withLock { $0.reason } }
    var isStopped: Bool { state.withLock { $0.stopped } }

    /// Runs a native function: termination is held off until it has returned, since JavaScriptCore
    /// cannot terminate inside a native call (it crashes converting the call's result).  Natives
    /// return `JSValue`s made inside `body` for the same reason.
    func native<T>(_ body: () throws -> T) rethrows -> T {
        state.withLock { $0.native += 1 }
        defer { state.withLock { $0.native -= 1 } }
        return try body()
    }

    /// Whether the script must stop now; records why.  Never while a native function runs.
    func shouldTerminate() -> Bool {
        state.withLock { current in
            if current.native > 0 { return false }
            if current.stopped { return true }
            if Date().timeIntervalSince(current.progress) > limits.wallClock {
                current.reason = .timeout
                current.stopped = true
                return true
            }
            if Self.footprint() - baseline > limits.memory {
                current.reason = .memoryLimit
                current.stopped = true
                return true
            }
            return false
        }
    }

    /// The process's physical footprint in bytes.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }

    // JavaScriptCore's `JSContextGroupSetExecutionTimeLimit` (JSContextRefPrivate.h), looked up
    // at run time: the one way to interrupt a running script from outside.
    typealias ShouldTerminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, ShouldTerminate?, UnsafeMutableRawPointer?) -> Void

    static let setLimit: SetLimit? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()

    /// The poll: terminate, or re-arm for the next 50 ms (JavaScriptCore calls the callback once
    /// per arming).
    static let poll: ShouldTerminate = { context, info in
        guard let info else { return false }
        if Unmanaged<ScriptWatchdog>.fromOpaque(info).takeUnretainedValue().shouldTerminate() { return true }
        setLimit?(JSContextGetGroup(context), 0.05, poll, info)
        return false
    }

    /// Arms the limit on `context`'s group; the watchdog must outlive the context.
    func arm(_ context: JSContext) {
        Self.setLimit?(JSContextGetGroup(context.jsGlobalContextRef), 0.05, Self.poll, Unmanaged.passUnretained(self).toOpaque())
    }
}

/// A script loaded into its own context: the sandbox, `console`, timers and the watchdog; `wt` is
/// installed by the caller (`ScriptEnvironment`).  Used from one thread at a time.
public final class ScriptContext: @unchecked Sendable {
    public let name: String
    let machine: JSVirtualMachine
    let context: JSContext
    let watchdog: ScriptWatchdog
    private(set) var console: [ScriptConsoleEntry] = []
    private var exception: JSValue?
    private var timers: [(id: Int, due: Date, callback: JSValue)] = []
    private var nextTimer = 1
    /// Where console lines go as they are written (the Script Editor's console).
    var onConsole: ((ScriptConsoleEntry) -> Void)?
    /// The `wt` environment installed in this context, kept alive with it.
    var environment: AnyObject?

    public init(name: String, limits: ScriptLimits = .standard) {
        self.name = name
        machine = JSVirtualMachine()
        context = JSContext(virtualMachine: machine)
        watchdog = ScriptWatchdog(limits: limits)
        watchdog.arm(context)
        context.name = name
        context.exceptionHandler = { [weak self] _, value in
            self?.exception = value
        }
        installSandbox()
    }

    /// A native function reachable from JavaScript under `__wt.<name>`.
    func native(_ name: String, _ block: Any) {
        let host = context.objectForKeyedSubscript("__wt")!
        host.setObject(block, forKeyedSubscript: name as NSString)
    }

    /// Throws a JavaScript error from inside a native function.
    static func raise(_ message: String) {
        guard let context = JSContext.current() else { return }
        context.exception = JSValue(newErrorFromMessage: message, in: context)
    }

    func log(_ level: ScriptConsoleEntry.Level, _ text: String) {
        let entry = ScriptConsoleEntry(level, text)
        console.append(entry)
        onConsole?(entry)
    }

    private func installSandbox() {
        context.setObject(JSValue(newObjectIn: context), forKeyedSubscript: "__wt" as NSString)
        // The context owns the JSContext that holds these blocks, so `unowned` cannot dangle.
        let log: @convention(block) (String, String) -> Void = { [unowned self] level, text in
            watchdog.native { self.log(ScriptConsoleEntry.Level(rawValue: level) ?? .log, text) }
        }
        native("log", log)
        let setTimer: @convention(block) (JSValue, Double) -> JSValue = { [unowned self] callback, milliseconds in
            watchdog.native {
                let delay = min(max(milliseconds.isFinite ? milliseconds : 0, 0) / 1000, watchdog.limits.maxTimeout)
                let id = nextTimer
                nextTimer += 1
                timers.append((id, Date().addingTimeInterval(delay), callback))
                return JSValue(int32: Int32(truncatingIfNeeded: id), in: context)
            }
        }
        native("setTimeout", setTimer)
        let clearTimer: @convention(block) (Int) -> Void = { [unowned self] id in
            watchdog.native { timers.removeAll { $0.id == id } }
        }
        native("clearTimeout", clearTimer)
        let limit = watchdog.limits.memory
        context.evaluateScript(ScriptPrelude.sandbox(memoryLimit: limit))
    }

    /// Evaluates the script (module syntax wrapped), then runs its timers until none are left;
    /// throws the first uncaught error or the watchdog's reason.  Returns the exports.
    @discardableResult
    public func load(_ source: String) throws -> JSValue {
        let wrapped = ScriptModuleSource.wrap(source)
        exception = nil
        context.evaluateScript(wrapped.code, withSourceURL: URL(string: "script:\(name)"))
        try check()
        // An async body: surface a rejection after it settles.
        _ = context.evaluateScript("__run.catch(function (e) { globalThis.__failure = e; });")
        try runTimers()
        try settled()
        return context.objectForKeyedSubscript("__exports")
    }

    /// Calls the exported function `name` with `arguments`, awaiting a returned promise; throws
    /// `missingExport` when there is none.
    public func call(_ name: String, _ arguments: [Any]) throws -> Any? {
        let exports = context.objectForKeyedSubscript("__exports")
        guard let function = exports?.objectForKeyedSubscript(name), !function.isUndefined, function.isObject else { throw ScriptError.missingExport(name) }
        exception = nil
        context.setObject(NSNull(), forKeyedSubscript: "__failure" as NSString)
        context.setObject(NSNull(), forKeyedSubscript: "__result" as NSString)
        let value = function.call(withArguments: arguments)
        try check()
        guard let value else { return nil }
        context.setObject(value, forKeyedSubscript: "__value" as NSString)
        context.evaluateScript("""
        Promise.resolve(__value).then(function (v) { globalThis.__result = { value: v }; }, function (e) { globalThis.__failure = e; });
        """)
        try runTimers()
        try settled()
        let result = context.objectForKeyedSubscript("__result")
        guard let result, result.isObject else { return nil }
        guard let resolved = result.objectForKeyedSubscript("value") else { return nil }
        return Self.plain(resolved)
    }

    /// A JavaScript value as Swift: strings, numbers, booleans, arrays, dictionaries; null and
    /// undefined as nil (inside containers as `NSNull`).
    static func plain(_ value: JSValue) -> Any? {
        if value.isUndefined || value.isNull { return nil }
        return value.toObject()
    }

    /// Throws for an exception the last evaluation left, or the watchdog's reason.
    private func check() throws {
        if let reason = watchdog.reason { throw reason }
        guard let exception else { return }
        self.exception = nil
        throw Self.error(exception)
    }

    private func settled() throws {
        try check()
        let failure = context.objectForKeyedSubscript("__failure")
        if let failure, !failure.isNull, !failure.isUndefined {
            context.setObject(NSNull(), forKeyedSubscript: "__failure" as NSString)
            if let reason = watchdog.reason { throw reason }
            throw Self.error(failure)
        }
    }

    /// Runs due timers in order until none are left (sleeping in short steps so a stop is
    /// noticed); the wall clock keeps counting.
    private func runTimers() throws {
        while let next = timers.min(by: { $0.due < $1.due }) {
            while Date() < next.due {
                if watchdog.shouldTerminate() { throw watchdog.reason ?? .stopped }
                Thread.sleep(forTimeInterval: min(0.01, max(0, next.due.timeIntervalSinceNow)))
            }
            timers.removeAll { $0.id == next.id }
            next.callback.call(withArguments: [])
            try check()
        }
        if watchdog.shouldTerminate() { throw watchdog.reason ?? .stopped }
    }

    /// The `ScriptError` of a thrown JavaScript value, with its line and column.
    static func error(_ value: JSValue) -> ScriptError {
        let message = value.isObject ? (value.objectForKeyedSubscript("name").toString().map { name in
            let text = value.objectForKeyedSubscript("message").toString() ?? ""
            return name == "undefined" ? value.toString() ?? "Error" : "\(name): \(text)"
        } ?? "Error") : (value.toString() ?? "Error")
        if message.contains("JavaScript execution terminated") { return .stopped }
        if message.contains("OfflineError: ") { return .offline }
        let line = value.isObject ? value.objectForKeyedSubscript("line").map { $0.isNumber ? Int($0.toInt32()) : nil } ?? nil : nil
        let column = value.isObject ? value.objectForKeyedSubscript("column").map { $0.isNumber ? Int($0.toInt32()) : nil } ?? nil : nil
        return .exception(message: message, line: line, column: column)
    }

    /// Stops the script after the current JavaScript statement (from any thread).
    public func stop() {
        watchdog.stop()
    }
}
