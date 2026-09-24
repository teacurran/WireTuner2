import Foundation
import Testing
import WTCRDT
import WTGeometry
@testable import WTModel
import WTProto
import WTRender

/// Edge cases of the data and scripting code: less common kinds and members, stops inside a
/// transaction, split placeholders and common-props editing at the wire level.
@Suite(.serialized) struct DataEdgeTests {
    @Test func membersOfLessCommonKinds() throws {
        var a = Replica(0xA)
        let page = try PageFixture.onePage(&a)
        try a.perform(NewMasterPage(from: page, name: "Master"))
        try a.perform(CreateLayer(name: "Art"))
        let layer = LayerOrder(a.state).layers[0].id
        var image = Wiretuner_Doc_V1_NodeProps()
        image.image.sourceName = "p"
        image.image.common.name = "Photo"
        try a.perform(OpsCommand("Place", ops: [Ops.create(parent: layer, position: [0x10], props: image)]))
        try DataFixture.source(&a, name: "Orders", kind: .http) { $0.http.url = "https://api.example.com" }
        let target = CoreScriptTarget(a.core)
        let result = ScriptRunner(limits: ScriptRuntimeTests.quick).run("""
        const m = wt.document.masterPages;
        console.log(m.length, m[0].kind, m[0].name);
        const img = wt.document.objects.where({ kind: "image" })[0];
        console.log(img.name, img.kind);
        const L = wt.document.layers[0];
        console.log(L.visible, L.locked);
        const b = wt.document.createBarcode({ value: "1" });
        console.log(b.symbology);
        const t = wt.document.createText({});
        t.text = "abc";
        t.text = 5;
        console.log(t.text);
        const r = wt.document.createRectangle();
        r.name = null;
        console.log(JSON.stringify(r.name), wt.document.dataSources[0].kind);
        __wt.end();
        __wt.log("weird", "level");
        try { __wt.list("bogus"); } catch (e) { console.log("bogus list"); }
        try { __wt.call(r.id, "spin", null); } catch (e) { console.log(e.message); }
        console.log(__wt.get("nope", "name"), __wt.get("999-9", "name"));
        try { __wt.set("nope", "name", "x"); } catch (e) { console.log("no node"); }
        setTimeout(function () { console.log("nan delay"); }, NaN);
        try { throw { message: "plain object" }; } catch (e) { console.log(e.message); }
        """, name: "Edge", target: target)
        #expect(result.error == nil, "\(String(describing: result.error))")
        #expect(result.console.map(\.text) == ["1 masterPage Master", "Photo image", "true false", "qr", "5", "\"\" http", "level", "bogus list", "spin is not available here",
                                              "undefined undefined", "no node", "plain object", "nan delay"])
        #expect(result.console[6].level == .log)
        let (thrown, _) = try ScriptRuntimeTests.run("throw { message: 'm' };")
        #expect(thrown.error == .exception(message: "[object Object]", line: nil, column: nil))
    }

    @Test func stopInsideATransactionKeepsWhatWasQueuedAsOneChange() throws {
        let target = try ScriptRuntimeTests.target()
        _ = ScriptRunner(limits: ScriptRuntimeTests.quick).run("wt.document.createRectangle();", name: "Setup", target: target)
        let before = target.changes.count
        let host = ScriptRuntimeTests.Host()
        host.cancelAfter = 3
        let result = ScriptRunner(limits: ScriptRuntimeTests.quick).run("""
        wt.document.transaction("Loop", function () {
          const p = wt.ui.progress("Working");
          for (let i = 0; ; i++) { wt.document.objects[0].name = "n" + i; p.update(0.1); }
        });
        """, name: "Stop", target: target, host: host)
        #expect(result.error == .stopped)
        let batch = Array(target.changes[before...])
        #expect(batch.count == 1 && batch[0].label == "Script: Loop")
        // A stop while a timer is pending ends the wait.
        let runner = ScriptRunner(limits: ScriptLimits(wallClock: 10, memory: 1 << 30, maxTimeout: 5))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { runner.stop() }
        let waiting = runner.run("setTimeout(function () {}, 3000);", name: "Wait", target: target)
        #expect(waiting.error == .stopped)
    }

    @Test func splitPlaceholdersAndWireLevelCommonEdits() throws {
        var a = Replica(0xA)
        let field = try DataFixture.fields(&a, ["name"])[0]
        let node = try DataFixture.placeholderBlock(&a, "", field: field, at: 0)
        // Format the middle of the placeholder: two runs of one field, replaced once.
        try a.perform(ApplyMark(node: node, from: TextFixture.at(a, node, 3), to: TextFixture.at(a, node, 5), value: TextFixture.size(30)))
        let text = MergeText(TextNode(node, in: a.state)!)
        #expect(text.paragraphs[0].runs.count == 3)
        let merged = text.substituting { _ in "Ada" }
        #expect(merged.string == "Ada" && merged.paragraphs[0].runs.count == 1)
        #expect(text.scaled(by: 2).largestSize == 60)
        // CommonProps edited on any kind at the wire level.
        var path = Wiretuner_Doc_V1_NodeProps()
        path.path.common.name = "p"
        path.path.common.dataBinding.kind = .visibility
        MergeToPages.setCommon(&path) { $0.url = "https://x"; $0.clearDataBinding() }
        #expect(path.path.common.url == "https://x" && path.path.common.name == "p" && !path.path.common.hasDataBinding)
        var empty = Wiretuner_Doc_V1_NodeProps()
        MergeToPages.setCommon(&empty) { $0.url = "x" }
        #expect(empty.kind == nil)
        var bare = Wiretuner_Doc_V1_NodeProps()
        bare.ellipse = .init()
        MergeToPages.setCommon(&bare) { $0.name = "e" }
        #expect(bare.ellipse.common.name == "e")
    }
}
