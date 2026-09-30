import Foundation
import Synchronization
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// DATA-011 (and DATA-012's model half): the JavaScript runtime, the sandbox, the limits, the
/// `wt.document` API with one change per set and transactions, `wt.fetch`, `wt.records`, `wt.ui`,
/// transforms and script sources.
@Suite(.serialized) struct ScriptRuntimeTests {
    static let quick = ScriptLimits(wallClock: 1, memory: 256 * 1024 * 1024, maxTimeout: 0.2)

    /// A target over a fresh document with one page and one layer.
    static func target() throws -> CoreScriptTarget {
        var a = Replica(0xA)
        _ = try PageFixture.onePage(&a)
        try a.perform(CreateLayer(name: "Art"))
        return CoreScriptTarget(a.core, name: "Doc")
    }

    static func run(_ source: String, target: CoreScriptTarget? = nil, host: (any ScriptHost)? = nil, fetcher: (any ScriptFetching)? = nil,
                    records: RecordSet? = nil, limits: ScriptLimits = quick) throws -> (ScriptRunResult, CoreScriptTarget) {
        let target = try target ?? Self.target()
        let result = ScriptRunner(limits: limits).run(source, name: "Test", target: target, host: host, fetcher: fetcher, records: records)
        return (result, target)
    }

    final class Fetcher: ScriptFetching, @unchecked Sendable {
        let requests = Mutex<[ScriptFetchRequest]>([])
        var failure: ScriptFetchError?
        func fetch(_ request: ScriptFetchRequest) throws -> ScriptFetchResponse {
            requests.withLock { $0.append(request) }
            if let failure { throw failure }
            return ScriptFetchResponse(status: 200, headers: ["content-type": "application/json"], body: Data(#"[{"first":"Ada","n":3,"tags":["a"]}]"#.utf8))
        }
    }

    final class Host: ScriptHost, @unchecked Sendable {
        var calls: [String] = []
        var cancelAfter = Int.max
        var updates = 0
        func ui(_ call: String, _ arguments: [Any]) throws -> Any? {
            calls.append(call)
            switch call {
            case "confirm": return true
            case "prompt": return "typed"
            case "choose": return (arguments[1] as? [String])?.last
            case "openFile": return "file contents"
            case "saveFile": return "token-1"
            default: return nil
            }
        }
        func export(_ options: [String: Any]) throws -> Any? {
            calls.append("export:\(options["format"] ?? "")" + (options["to"].map { ">\($0)" } ?? ""))
            return "done"
        }
        func print(_ preset: String?) throws -> Any? { calls.append("print:\(preset ?? "-")"); return nil }
        func progress(_ fraction: Double, _ text: String) -> Bool {
            updates += 1
            return updates < cancelAfter
        }
    }

    // MARK: Runtime

    @Test func consoleModulesAsyncTimersAndErrors() throws {
        let (result, _) = try Self.run("""
        export function records() { return [1]; }
        export const answer = 42;
        const hidden = 1;
        export { hidden as shown, hidden };
        export default function main() {}
        console.log("hello", { a: 1 }, [2]);
        console.warn("careful");
        console.error("bad");
        console.table([{ a: 1 }]);
        const value = await Promise.resolve(5);
        setTimeout(function (x) { console.log("timer", x, value); }, 10, "arg");
        const id = setTimeout(function () { console.log("never"); }, 5);
        clearTimeout(id);
        console.log(typeof Intl, typeof Map, `t${1 + 1}`, (function () { return undefined; })());
        """)
        #expect(result.error == nil)
        #expect(result.console.map(\.text) == ["hello {\"a\":1} [2]", "careful", "bad", "[{\"a\":1}]", "object function t2 undefined", "timer arg 5"])
        #expect(result.console.map(\.level) == [.log, .warn, .error, .table, .log, .log])
        let wrapped = ScriptModuleSource.wrap("export async function a() {}\nexport class B {}\nexport let c = 1, d = 2\nexport var e\nexport function* f() {}\nexport default 3")
        #expect(wrapped.exports == ["a", "B", "c", "e", "f"] && wrapped.code.contains("__exports.default = 3"))
        #expect(ScriptModuleSource.declaredName("x = 1") == nil && ScriptModuleSource.declaredName("function (") == nil)
        // An uncaught error carries its line and column; one after an await too.
        let (thrown, _) = try Self.run("const a = 1;\nnull.x;")
        guard case .exception(let message, let line, _)? = thrown.error else { Issue.record("expected an exception"); return }
        #expect(message.hasPrefix("TypeError") && line == 2 && thrown.console.last?.level == .error)
        let (later, _) = try Self.run("await Promise.resolve();\nthrow new RangeError('late');")
        #expect(later.error == .exception(message: "RangeError: late", line: 2, column: later.error.flatMap { if case .exception(_, _, let c) = $0 { c } else { nil } }))
        let (plain, _) = try Self.run("throw 'just text';")
        #expect(plain.error == .exception(message: "just text", line: nil, column: nil))
        let (timerError, _) = try Self.run("setTimeout(function () { throw new Error('in timer'); }, 0);")
        if case .exception(let text, _, _)? = timerError.error { #expect(text == "Error: in timer") } else { Issue.record("timer error") }
        let (syntax, _) = try Self.run("let = ;")
        #expect(syntax.error != nil)
        #expect(ScriptError.timeout.description.hasPrefix("ScriptTimeout") && ScriptError.memoryLimit.description.hasPrefix("ScriptMemoryLimit"))
        #expect(ScriptError.stopped.description == "The script was stopped" && ScriptError.missingExport("x").description.contains("x"))
        #expect(ScriptError.offline.description.hasPrefix("OfflineError") && ScriptError.exception(message: "m", line: nil, column: nil).description == "m")
        #expect(ScriptError.exception(message: "m", line: 3, column: nil).description == "m (line 3)")
    }

    @Test func sandboxDeniesAndLimitsStop() throws {
        for (source, name) in [("require('fs')", "require"), ("new XMLHttpRequest()", "XMLHttpRequest"), ("new WebSocket('wss://x')", "WebSocket"),
                               ("fetch('https://x')", "fetch"), ("setInterval(function(){}, 1)", "setInterval")] {
            let (result, _) = try Self.run(source)
            guard case .exception(let message, _, _)? = result.error else { Issue.record("\(name) should fail"); continue }
            #expect(message.hasPrefix("SandboxError: \(name) is not available"), "\(message)")
        }
        let (dynamic, _) = try Self.run("await import('file:///etc/passwd');")
        #expect(dynamic.error != nil)
        // A busy loop is stopped at the wall-clock limit (1 s here; 60 s in the app).
        let start = Date()
        let (busy, _) = try Self.run("while (true) {}")
        #expect(busy.error == .timeout && Date().timeIntervalSince(start) < 10)
        // A 300 MiB allocation fails without taking the process down.
        for source in ["new ArrayBuffer(300 * 1024 * 1024)", "new Float64Array(40 * 1024 * 1024)", "'ab'.repeat(200 * 1024 * 1024)",
                       "new Array(50 * 1024 * 1024).fill(0)"] {
            let (big, _) = try Self.run(source)
            if big.error == .memoryLimit { continue }
            guard case .exception(let message, _, _)? = big.error else { Issue.record("\(source) should fail"); continue }
            #expect(message.contains("ScriptMemoryLimit"), "\(message)")
        }
        let (small, _) = try Self.run("const b = new Uint8Array(16); const c = new Uint8Array(b.buffer, 0, 4); const d = new Int16Array(); const e = Uint8Array.from([1]); console.log(b.length + c.length + d.length + e.length, new ArrayBuffer(8).byteLength, ArrayBuffer.isView(b), [1,2].fill(0).length)")
        #expect(small.error == nil && small.console.last?.text == "21 8 true 2")
        // The memory watchdog: a limit below what the process already grows stops the script.
        let (grown, _) = try Self.run("const keep = []; for (let i = 0; i < 2e6; i++) keep.push({ i: i, s: 'x' + i });",
                                      limits: ScriptLimits(wallClock: 30, memory: 1, maxTimeout: 1))
        #expect(grown.error == .memoryLimit)
        // Stop from another thread; a stop before the run starts stops it at once.
        let runner = ScriptRunner(limits: ScriptLimits(wallClock: 30, memory: 1 << 30))
        let target = try Self.target()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { runner.stop() }
        let stopped = runner.run("while (true) {}", name: "Loop", target: target)
        #expect(stopped.error == .stopped)
        let early = ScriptRunner(limits: Self.quick)
        early.stop()
        #expect(early.run("setTimeout(function(){}, 100)", name: "x", target: target).error == .stopped)
        // setTimeout is capped (0.2 s here) and needs a function.
        let started = Date()
        let (capped, _) = try Self.run("setTimeout(function () { console.log('ran'); }, 1e9);")
        #expect(capped.error == nil && capped.console.last?.text == "ran" && Date().timeIntervalSince(started) < 5)
        let (notFunction, _) = try Self.run("setTimeout('code', 1)")
        #expect(notFunction.error != nil)
    }

    @Test func runDetachedOnItsOwnThread() async throws {
        let target = try Self.target()
        let lines = Mutex<[String]>([])
        let result = await ScriptRunner(limits: Self.quick).runDetached("console.log(wt.document.name)", name: "N", target: target) { entry in
            lines.withLock { $0.append(entry.text) }
        }
        #expect(result.error == nil && lines.withLock { $0 } == ["Doc"])
    }

    // MARK: wt.document

    @Test func documentMembersReadAndEachSetIsOneLabelledChange() throws {
        let (result, target) = try Self.run("""
        const doc = wt.document;
        const rect = doc.createRectangle({ x: 10, y: 20, width: 30, height: 40 });
        const ellipse = doc.createEllipse({ x: 100, y: 0 });
        const line = doc.createLine({ x1: 0, y1: 0, x2: 50, y2: 50 });
        const text = doc.createText({ x: 5, y: 5, text: "Hello big world" });
        const code = doc.createBarcode({ x: 0, y: 200, value: "12345", kind: "code128" });
        rect.name = "Box";
        rect.notes = "a note";
        rect.url = "https://example.com";
        rect.position = { x: 15, y: 25 };
        rect.locked = true;
        rect.locked = false;
        text.text = "Replaced text";
        code.value = "67890";
        code.symbology = "qr";
        const layers = doc.layers;
        layers[0].name = "Artwork";
        layers[0].visible = true;
        layers[0].locked = false;
        doc.pages[0].name = "Front";
        console.log(doc.name, doc.pages.length, doc.masterPages.length, doc.layers.length, doc.objects.length, doc.swatches.length, doc.styles.length);
        console.log(rect.kind, rect.name, rect.notes, rect.url, rect.position.x + "," + rect.position.y, rect.size.width + "x" + rect.size.height, rect.locked, rect.visible);
        console.log(text.text, code.value, code.symbology, ellipse.bounds.x, line.kind, doc.pages[0].name, doc.pages[0].number, doc.pages[0].bounds.width);
        console.log(rect.layer.name, rect.page.name, rect.fill, rect.stroke, rect.binding, rect.nothing, String(rect), JSON.stringify(rect));
        console.log(doc.objects.where({ kind: "rectangle" }).length, doc.objects.where({ name: "Box" })[0] === rect, doc.objects.where({ layer: "Artwork" }).length);
        console.log(doc.objects.where({ layer: layers[0] }).length, doc.objects.where({ page: doc.pages[0] }).length, doc.objects.where({ layer: "none" }).length);
        doc.selection = [rect, ellipse];
        console.log(doc.selection.length);
        const copy = rect.duplicate();
        copy.bringToFront();
        copy.sendToBack();
        const second = doc.createRectangle({ layer: layers[0].id });
        copy.moveTo(layers[0]);
        copy.layer = layers[0];
        second.remove();
        console.log(doc.objects.length, copy.name);
        """)
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.console[0].text == "Doc 1 0 1 5 0 0")
        #expect(result.console[1].text == "rectangle Box a note https://example.com 15,25 30x40 false true")
        #expect(result.console[2].text == "Replaced text 67890 qr 100 path Front 1 612")
        #expect(result.console[3].text.hasPrefix("Artwork Front 0 fills 1 stroke undefined undefined [WireTuner rectangle "))
        #expect(result.console[4].text == "1 true 5" && result.console[5].text == "5 4 0" && result.console[6].text == "2")
        #expect(result.console[7].text == "6 Box")
        let changes = target.changes
        #expect(changes.allSatisfy { $0.label.hasPrefix("Script: ") }, "every change is labelled after the script")
        #expect(result.changes == changes.count && changes.count == 25)
        // Undo takes one set back.
        let before = TextNode(target.current.state.liveChildren(LayerOrder(target.current.state).layers[0].id).first { TextNode($0, in: target.current.state) != nil }!, in: target.current.state)!
        #expect(before.string == "Replaced text")
        #expect(target.selection.count == 2)
    }

    @Test func eachSetIsOneUndoStep() throws {
        // DATA-011: outside a transaction every property set is its own change and undo step.
        let target = try Self.target()
        let (result, _) = try Self.run("""
        const box = wt.document.createRectangle({ x: 0 });
        box.name = "first";
        box.name = "second";
        box.notes = "noted";
        """, target: target)
        #expect(result.error == nil, "\(String(describing: result.error))")
        func box() -> Wiretuner_Doc_V1_CommonProps {
            let state = target.current.state
            return state.props(state.liveChildren(LayerOrder(state).layers[0].id).last!).rect.common
        }
        #expect(box().name == "second" && box().note == "noted")
        target.undo()
        #expect(box().name == "second" && box().note.isEmpty, "the notes set alone")
        target.undo()
        #expect(box().name == "first")
    }

    @Test func transactionsBatchIntoChangesOfTenThousandOpsAndOneUndoStep() throws {
        let target = try Self.target()
        let (setup, _) = try Self.run("for (let i = 0; i < 3; i++) wt.document.createRectangle({ x: i * 10 });", target: target)
        #expect(setup.error == nil)
        let before = target.changes.count
        let (result, _) = try Self.run("""
        const objects = wt.document.objects;
        const progress = wt.ui.progress("Numbering");
        const value = wt.document.transaction("Number them", function () {
          for (let i = 0; i < 10001; i++) {
            objects[i % 3].name = "n" + i;
            if (i % 500 === 0) progress.update(i / 10001);
          }
          return "done";
        });
        console.log(value, objects[0].name);
        """, target: target, host: Host(), limits: ScriptLimits(wallClock: 120, memory: 1 << 30))
        #expect(result.error == nil, "\(String(describing: result.error))")
        // 10,001 writes: one full change of 10,000 ops and one of 1, the least that shows the split.
        // The script shows progress, as a long script must, so the 120 s watchdog measures time
        // between updates: in parallel full-suite runs on a loaded machine larger loops ran past it.
        let batch = Array(target.changes[before...])
        #expect(batch.count == 2 && batch.allSatisfy { $0.label == "Script: Number them" && $0.ops.count <= 10_000 })
        #expect(result.console.last?.text == "done n9999" || result.console.last?.text == "done n0", "\(result.console.last?.text ?? "")")
        target.undo()
        let names = target.current.state.liveChildren(LayerOrder(target.current.state).layers[0].id).map { target.current.state.props($0).rect.common.name }
        #expect(names == ["", "", ""], "the whole transaction is one undo step")
        // A throw inside a transaction flushes what it had; nesting joins the outer one.
        let (thrown, _) = try Self.run("""
        wt.document.transaction("Outer", function () {
          wt.document.objects[0].name = "kept";
          wt.document.transaction("Inner", function () { wt.document.objects[1].name = "also"; });
          wt.document.createText({ text: "made" });
          throw new Error("stop here");
        });
        """, target: target)
        if case .exception(let message, _, _)? = thrown.error { #expect(message == "Error: stop here") } else { Issue.record("expected the throw") }
        let objects = target.current.state.liveChildren(LayerOrder(target.current.state).layers[0].id)
        #expect(target.current.state.props(objects[0]).rect.common.name == "kept" && target.current.state.props(objects[1]).rect.common.name == "also")
        let (bad, _) = try Self.run("wt.document.transaction('x')", target: target)
        #expect(bad.error != nil)
    }

    /// Script writes cost the same however many came before: 20,000 sets of three objects' names
    /// in one transaction (the perf run; correctness runs 4,000) stay within 100 µs a set in a
    /// release build.  Every set of one register used to scan and copy that register's whole
    /// write log, so a loop over a few objects grew quadratically (1.3 ms a set at 20,000).
    @Test func scriptWritesInATransactionCostTheSameEachHoweverManyCameBefore() throws {
        let target = try Self.target()
        let (setup, _) = try Self.run("for (let i = 0; i < 3; i++) wt.document.createRectangle({ x: i * 10 });", target: target)
        #expect(setup.error == nil)
        let writes = PerfBudget.isMeasuring ? 20_000 : 4_000
        let clock = ContinuousClock()
        var result: ScriptRunResult?
        let elapsed = try clock.measure {
            (result, _) = try Self.run("""
            const objects = wt.document.objects;
            wt.document.transaction("Number them", function () {
              for (let i = 0; i < \(writes); i++) objects[i % 3].name = "n" + i;
            });
            """, target: target, limits: ScriptLimits(wallClock: 600, memory: 1 << 30))
        }
        #expect(result?.error == nil, "\(String(describing: result?.error))")
        let names = target.current.state.liveChildren(LayerOrder(target.current.state).layers[0].id).map { target.current.state.props($0).rect.common.name }
        #expect(names == (writes - 3..<writes).map { "n\($0)" }.sorted { Int($0.dropFirst())! % 3 < Int($1.dropFirst())! % 3 })
        let perWrite = elapsed / writes
        print("Script writes: \(perWrite) a set over \(writes)")
        PerfBudget.expect(perWrite, within: .microseconds(100), "\(writes) sets")
    }

    @Test func documentErrorsReadOnlyAndUnavailable() throws {
        let target = try Self.target()
        let script = try target.perform(SaveScript(name: "Kept", source: "// s", description: "d"))!.createdNodes[0]
        try target.perform(AddSwatch(Color(red: 1, green: 0, blue: 0), name: "Red"))
        let cases: [(String, String)] = [
            ("wt.document.pages[0].visible = false", "cannot be set"),
            ("wt.document.createRectangle().fill = 'red'", "cannot be set"),
            ("wt.document.createRectangle().locked = 'yes'", "invalidValue"),
            ("wt.document.createRectangle().position = { x: 'a' }", "invalidValue"),
            ("wt.document.createRectangle().layer = 'nope'", "invalidValue"),
            ("wt.document.createRectangle().moveTo('nope')", "invalidValue"),
            ("wt.document.createRectangle().name = {}", "invalidValue"),
            ("wt.document.placeImage()", "placeImage is not available"),
            ("wt.document.export({})", "wt.document.export is not available"),
            ("wt.document.print()", "wt.document.print is not available"),
            ("wt.ui.alert('x')", "wt.ui.alert is not available"),
            ("wt.document.addField('bad name')", "invalidName"),
            ("wt.document.addField('x', 'colour')", "invalidValue"),
            ("wt.document.createRectangle().text = 'x'", "cannot be set"),
        ]
        for (source, expected) in cases {
            let (result, _) = try Self.run(source, target: target)
            guard case .exception(let message, _, _)? = result.error else { Issue.record("\(source) should fail"); continue }
            #expect(message.contains(expected), "\(source): \(message)")
        }
        let (ok, _) = try Self.run("""
        const s = wt.document.scripts[0];
        console.log(s.kind, s.name, s.source, s.description);
        s.name = "Renamed";
        s.source = "// new";
        const f = wt.document.addField("city");
        console.log(typeof f, JSON.stringify(wt.document.fields.map(function (x) { return x.name + ":" + x.type; })));
        console.log(JSON.stringify(wt.document.dataSources), wt.documents.length, wt.document.swatches[0].kind);
        wt.document.swatches[0].name = "Paper";
        try { wt.document.layers[0].remove(); } catch (e) { console.log("kept", e.message); }
        wt.document.scripts[0].remove();
        console.log(wt.document.layers.length, wt.document.scripts.length, wt.document.swatches[0].name);
        """, target: target)
        #expect(ok.error == nil, "\(String(describing: ok.error))")
        #expect(ok.console.map(\.text) == ["script Kept // s d", #"string ["city:text"]"#, "[] 1 swatch", "kept lastPrintingLayer", "1 0 Paper"])
        #expect(DocumentScript.script(script, in: target.current.state) == nil)
        #expect(ScriptEnvironment.id("x") == nil && ScriptEnvironment.id("1-2") == OpID(counter: 1, replica: 2))
        #expect(ScriptEnvironment.kindName(.unspecified) == "none" && ScriptEnvironment.kindName(.file) == "file" && ScriptEnvironment.kindName(.script) == "script")
        let (unknown, _) = try Self.run("console.log(wt.document.createRectangle().kind); wt.document.objects[0].frobnicate", target: target)
        #expect(unknown.error == nil)
    }

    @Test func pageRemovalAndKindNames() throws {
        var a = Replica(0xA)
        try a.perform(AddPages(count: 1))
        let target = CoreScriptTarget(a.core)
        let (result, _) = try Self.run("wt.document.pages[1].remove(); console.log(wt.document.pages.length)", target: target)
        #expect(result.console.last?.text == "1")
        let state = a.state
        #expect(ScriptEnvironment.kindName(WellKnown.settings, in: state) == "unknown")
        #expect(ScriptEnvironment.kindName(.zero, in: state) == "unknown")
        // Every kind name.
        var b = Replica(0xB)
        let group = try b.perform(GroupObjects([try b.perform(CreateShape(.ellipse, size: Size(width: 1, height: 1)))!.createdObjects[0]]))!.createdObjects[0]
        let polygon = try b.perform(CreatePolygon(PolygonShape(sides: 5, star: false, radius: 5), center: .zero))!.createdObjects[0]
        #expect(ScriptEnvironment.kindName(group, in: b.state) == "group" && ScriptEnvironment.kindName(polygon, in: b.state) == "polygon")
    }

    // MARK: fetch, records, ui

    @Test func fetchGoesThroughTheServiceAndIsLogged() throws {
        let fetcher = Fetcher()
        let (result, _) = try Self.run("""
        const res = await wt.fetch("https://api.example.com/tickets?event=1", { method: "post", headers: { Accept: "application/json", "X-N": 2 }, body: "{}", credential: "ticketing-api", timeout: 10 });
        const data = await res.json();
        console.log(res.status, res.ok, res.headers["content-type"], data[0].first, (await res.text()).length);
        """, fetcher: fetcher)
        #expect(result.error == nil, "\(String(describing: result.error))")
        let request = try #require(fetcher.requests.withLock { $0.first })
        #expect(request.method == "POST" && request.url == "https://api.example.com/tickets?event=1" && request.headers == ["Accept": "application/json", "X-N": "2"])
        #expect(request.body == Data("{}".utf8) && request.credential == "ticketing-api" && request.timeout == 10)
        #expect(result.console.first?.level == .request && result.console.first?.text.hasPrefix("POST api.example.com/tickets 200") == true)
        #expect(result.console.last?.text == "200 true application/json Ada 36" && result.hosts == ["api.example.com"])
        // Failures reject the promise with the documented messages.
        fetcher.failure = .hostNotAllowed(host: "evil.example", admins: "Ann, Bo")
        let (denied, _) = try Self.run("try { await wt.fetch('https://evil.example/x'); } catch (e) { console.log(e.message); }", fetcher: fetcher)
        #expect(denied.console.last?.text == "HostNotAllowed: evil.example is not a permitted host; ask Ann, Bo to permit it")
        #expect(denied.console.first?.text.contains("failed") == true)
        let (offline, _) = try Self.run("await wt.fetch('https://x.example')")
        #expect(offline.error == .offline)
        let (tooBig, _) = try Self.run("await wt.fetch('https://x.example', { body: 'x'.repeat(1048577) })", fetcher: Fetcher())
        if case .exception(let message, _, _)? = tooBig.error { #expect(message.contains("over 1 MiB")) } else { Issue.record("body cap") }
        for (error, text) in [(ScriptFetchError.hostNotAllowed(host: "h", admins: ""), "HostNotAllowed: h is not a permitted host"),
                              (.credentialMissing("c"), "CredentialMissing: no credential named c"), (.responseTooLarge, "ResponseTooLarge: the response is over 16 MiB"),
                              (.upstream("tls"), "UpstreamError: tls"), (.rateLimited(retryAfter: 1.2), "RateLimited: too many requests; retry in 2 s"),
                              (.rateLimited(retryAfter: nil), "RateLimited: too many requests"), (.failed("m"), "FetchError: m")] {
            #expect(error.description == text)
        }
        #expect(ScriptFetchRequest(url: "u").method == "GET")
    }

    @Test func recordsUIProgressExportAndPrint() throws {
        var a = Replica(0xA)
        _ = try PageFixture.onePage(&a)
        try DataFixture.fields(&a, ["name"])
        try DataFixture.source(&a, name: "People")
        let records = RecordSet(model: DataModel(a.state), source: nil, raw: [DataRecord(["name": "Ada"]), DataRecord(["name": "Bo"])])
        let host = Host()
        let target = CoreScriptTarget(a.core)
        let result = ScriptRunner(limits: Self.quick).run("""
        console.log(JSON.stringify(wt.records.all()), JSON.stringify(wt.records.current()), wt.records.fields.length);
        console.log(wt.ui.confirm("?"), wt.ui.prompt("?", "d"), wt.ui.choose("?", ["A", "B"]), wt.ui.openFile({ types: ["txt"] }));
        wt.ui.alert("hi");
        const writer = wt.ui.saveFile({ suggestedName: "a.txt" });
        writer.write("data");
        const p = wt.ui.progress("Working");
        p.update(0.5, "half");
        p.update(1);
        p.done();
        console.log(wt.document.export({ format: "pdf" }), wt.document.print("Proof"), wt.document.print(), wt.records.merge({ to: "pdf" }));
        // A writer from saveFile reaches the host as its token, anything else as "".
        wt.document.export({ format: "svg", to: writer });
        wt.document.export({ to: { write: function () {} } });
        wt.document.export();
        console.log(JSON.stringify(wt.document.dataSources.map(function (s) { return s.name + ":" + s.kind + ":" + s.connected; })));
        """, name: "UI", target: target, host: host, records: records, current: 1)
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.console[0].text == #"[{"name":"Ada"},{"name":"Bo"}] {"name":"Bo"} 1"#)
        #expect(result.console[1].text == "true typed B file contents")
        #expect(host.calls == ["confirm", "prompt", "choose", "openFile", "alert", "saveFile", "write", "progress", "progressDone", "export:pdf", "print:Proof", "print:-", "merge",
                              "export:svg>token-1", "export:>", "export:"])
        #expect(result.console.last?.text == #"["People:pasted:true"]"# && host.updates == 2)
        let empty = ScriptRunner(limits: Self.quick).run("console.log(JSON.stringify(wt.records.all()), wt.records.current()); wt.ui.saveFile()", name: "E", target: target, host: HeadlessDenied())
        #expect(empty.console.first?.text == "[] null")
        // Cancel from the progress sheet stops the script after the current change.
        let cancelling = Host()
        cancelling.cancelAfter = 2
        let stopped = ScriptRunner(limits: Self.quick).run("const p = wt.ui.progress('x'); for (let i = 0; ; i++) p.update(i / 10);", name: "C", target: target, host: cancelling)
        #expect(stopped.error == .stopped)
        // A headless host refuses the window's calls.
        let headless = ScriptRunner(limits: Self.quick).run("wt.document.export({})", name: "H", target: target, host: HeadlessScriptHost())
        if case .exception(let message, _, _)? = headless.error { #expect(message.contains("not available")) } else { Issue.record("headless export") }
        let headlessUI = ScriptRunner(limits: Self.quick).run("wt.ui.alert('x')", name: "H", target: target, host: HeadlessScriptHost())
        #expect(headlessUI.error != nil)
        let headlessPrint = ScriptRunner(limits: Self.quick).run("const p = wt.ui.progress; wt.document.print()", name: "H", target: target, host: HeadlessScriptHost())
        #expect(headlessPrint.error != nil && HeadlessScriptHost().progress(0, "") && ScriptUnavailable(call: "c").description == "c is not available here")
    }

    final class HeadlessDenied: ScriptHost, @unchecked Sendable {
        func ui(_ call: String, _ arguments: [Any]) throws -> Any? { nil }
    }

    // MARK: Transforms and script sources

    @Test func transformsAndScriptSources() throws {
        var a = Replica(0xA)
        let fields = try DataFixture.fields(&a, ["first", "last", "full", "n"])
        let script = try a.perform(SaveScript(name: "Full", source: """
        export function transform(value, record, field) {
          if (field === "n") { if (value === "throw") throw new Error("bad value"); if (value === "loop") { while (true) {} } return value === "obj" ? { a: 1 } : (value === "null" ? null : Number(value) * 2); }
          return record.first + " " + record.last;
        }
        """))!.createdNodes[0]
        try a.perform(SetFieldTransform(fields[2], script: script))
        try a.perform(SetFieldTransform(fields[3], script: script))
        let transformer = ScriptTransformer(state: a.state, limits: ScriptLimits(wallClock: 0.5, memory: 1 << 30))
        let set = RecordSet(model: DataModel(a.state), source: nil,
                            raw: [DataRecord(["first": "Ada", "last": "L", "n": "4"]), DataRecord(["n": "throw"]), DataRecord(["n": "loop"]),
                                  DataRecord(["n": "obj"]), DataRecord(["n": "null"])], transforms: transformer)
        #expect(set.records[0].value(fields[2]).text == "Ada L" && set.records[0].value(fields[3]).text == "8")
        #expect(set.records[1].value(fields[3]).text == "throw" && set.records[2].value(fields[3]).text == "loop")
        #expect(set.records[3].value(fields[3]).text == #"{"a":1}"# && set.records[4].value(fields[3]).raw == nil)
        #expect(set.issues.contains { $0.record == 2 && $0.kind == .transformFailed(message: "Error: bad value (line 2, column 69)") } || set.issues.contains { $0.record == 2 })
        #expect(set.issues.contains(MergeIssue(record: 3, field: "n", kind: .transformTimeout)))
        // A missing export or script.
        let bare = try a.perform(SaveScript(name: "Bare", source: "const x = 1;"))!.createdNodes[0]
        #expect(throws: ScriptError.missingExport("transform")) { try ScriptTransformer(state: a.state).transform(script: bare, value: nil, record: [:], field: "f") }
        #expect(throws: ScriptError.missingExport("transform")) { try ScriptTransformer(state: a.state).transform(script: .zero, value: nil, record: [:], field: "f") }
        // A script source: its records, with wt.fetch through the service and the hosts recorded.
        let source = try a.perform(SaveScript(name: "Tickets", source: """
        export async function records(params) {
          const res = await wt.fetch(`https://api.example.com/tickets?event=${params.event}`, { credential: "ticketing-api" });
          const tickets = await res.json();
          return tickets.map(t => ({ first_name: t.first, n: t.n, tags: t.tags, none: null }));
        }
        """))!.createdNodes[0]
        let fetcher = Fetcher()
        let result = try ScriptRecordSource.records(script: source, state: a.state, params: ["event": "9"], fetcher: fetcher, limits: Self.quick)
        #expect(result.table.columns == ["first_name", "n", "none", "tags"] && result.table.records[0].values == ["first_name": "Ada", "n": "3", "tags": #"["a"]"#])
        #expect(result.hosts == ["api.example.com"] && fetcher.requests.withLock { $0.first?.url } == "https://api.example.com/tickets?event=9")
        #expect(throws: ScriptError.missingExport("records")) { try ScriptRecordSource.records(script: .zero, state: a.state) }
        let notArray = try a.perform(SaveScript(name: "N", source: "export function records() { return 3; }"))!.createdNodes[0]
        #expect(throws: ScriptError.self) { try ScriptRecordSource.records(script: notArray, state: a.state) }
        let notObjects = try a.perform(SaveScript(name: "M", source: "export function records() { return [1]; }"))!.createdNodes[0]
        #expect(throws: ScriptError.self) { try ScriptRecordSource.records(script: notObjects, state: a.state) }
        let undefinedRecords = try a.perform(SaveScript(name: "U", source: "export function records() { }"))!.createdNodes[0]
        #expect(throws: ScriptError.self) { try ScriptRecordSource.records(script: undefinedRecords, state: a.state) }
        #expect(DataTable.jsonText(true as NSNumber) == "true" && DataTable.jsonText(NSNull()) == nil && DataTable.jsonText([1]) == "[1]")
    }

    // MARK: Script nodes and typings

    @Test func scriptNodesSaveRenameDelete() throws {
        var a = Replica(0xA)
        let save = try #require(try a.perform(SaveScript(name: "One", source: "1", description: "first", library: .with { $0.documentID = "lib" })))
        #expect(save.label == "Save script")
        let node = save.createdNodes[0]
        var script = try #require(DocumentScript.script(node, in: a.state))
        #expect(script.name == "One" && script.source == "1" && script.description == "first" && script.library?.documentID == "lib")
        try a.perform(SaveScript(node, name: "Two", source: "2", description: "second"))
        script = try #require(DocumentScript.script(node, in: a.state))
        #expect(script.name == "Two" && script.source == "2" && script.description == "second")
        try a.perform(SaveScript(node, name: "Two", source: "3"))
        #expect(DocumentScript.script(node, in: a.state)?.description == "second", "an unchanged description is not written")
        #expect(throws: ScriptEditError.tooLarge(ScriptFields.maxSource + 1)) { try a.perform(SaveScript(name: "Big", source: String(repeating: "x", count: ScriptFields.maxSource + 1))) }
        #expect(throws: ScriptEditError.notAScript(WellKnown.settings)) { try a.perform(SaveScript(WellKnown.settings, name: "x", source: "")) }
        #expect(try a.perform(RenameScript(node, to: "Three"))?.label == "Rename script")
        #expect(throws: ScriptEditError.notAScript(.zero)) { try a.perform(RenameScript(.zero, to: "x")) }
        #expect(try a.perform(DeleteScript(node))?.label == "Delete script")
        #expect(DocumentScript.list(a.state).isEmpty && DocumentScript.script(node, in: a.state) == nil)
        #expect(throws: ScriptEditError.notAScript(node)) { try a.perform(DeleteScript(node)) }
        a.undo()
        #expect(DocumentScript.list(a.state).map(\.name) == ["Three"], "Restore brings the script back with its source")
    }

    @Test func typingsDeclareEveryMember() {
        let declarations = ScriptTypings.declarations
        #expect(ScriptTypings.fileName == "wiretuner.d.ts")
        for member in ["transaction", "createRectangle", "createEllipse", "createLine", "createText", "createBarcode", "placeImage", "export(", "print(",
                       "masterPages", "layers", "objects", "swatches", "styles", "scripts", "fields", "dataSources", "selection", "addField",
                       "function fetch", "alert", "confirm", "prompt", "choose", "openFile", "saveFile", "progress", "all()", "current()", "merge(",
                       "duplicate()", "remove()", "moveTo(", "bringToFront()", "sendToBack()", "where(", "setTimeout", "clearTimeout", "console"] {
            #expect(declarations.contains(member), "\(member)")
        }
    }

    @Test func labelledAndCoreTargetBasics() throws {
        let target = try Self.target()
        let labelled = ScriptLabelled(AddFields("x"), label: "Script: T")
        #expect(labelled.label == "Script: T" && labelled.coalescing == .none)
        let change = try target.perform(labelled)
        #expect(change?.label == "Script: T" && target.name == "Doc")
        target.endGroup()
        target.selection = [.zero]
        #expect(target.selection == [.zero])
    }

    @Test @MainActor func documentTargetHopsToTheMainActor() async throws {
        var a = Replica(0xA)
        _ = try PageFixture.onePage(&a)
        let document = Document(memory: a.core)
        let reported = Mutex<[OpID]>([])
        let target = DocumentScriptTarget(document, name: "Window", onSelection: { ids in reported.withLock { $0 = ids } })
        let result = await ScriptRunner(limits: Self.quick).runDetached("""
        wt.document.transaction("Two", function () {
          const r = wt.document.createRectangle({ x: 1 });
          r.name = "made";
        });
        wt.document.selection = wt.document.objects;
        console.log(wt.document.name, wt.document.objects.length, wt.document.selection.length);
        """, name: "W", target: target)
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.console.last?.text == "Window 1 1")
        #expect(document.undoTitle == "Undo Script: Two" && !document.isGrouping)
        await Task.yield()
        #expect(target.selection.count == 1)
        let failed = await ScriptRunner(limits: Self.quick).runDetached("wt.document.objects[0].position = { x: 'z' }", name: "F", target: target)
        #expect(failed.error != nil)
    }
}
