import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTModel
import WTProto
@testable import WireTuner

/// COLLAB-018's timing: a branch with 10,000 changes against a parent that advanced 10,000 previews
/// in under 2 s.  The preview is the merge review's list (`BranchMergeModel.preview`, built off the
/// main actor from both states as this Mac holds them).  What it lists is checked in every run;
/// the time is a `PerfBudget`, held only in the perf run.
@Suite(.serialized) @MainActor struct BranchMergePerformanceTests {
    static let changes = 10_000
    static let objects = 4_000
    static let budget = 2.0

    /// `base` with `count` one-op changes by `replica`, each moving object `offset + i` (modulo
    /// the objects), so every object in the stretch is changed several times over.
    static func advanced(_ base: EngineState, nodes: [OpID], replica: UInt64, count: Int, offset: Int, stride: Int) -> EngineState {
        var state = base
        for index in 0..<count {
            let node = nodes[(offset + index % stride) % nodes.count]
            var values = Wiretuner_Doc_V1_NodeProps()
            values.rect.common.transform.a = 1
            values.rect.common.transform.d = 1
            values.rect.common.transform.tx = Double(index)
            values.rect.common.transform.ty = Double(replica % 1000)
            var change = Wiretuner_Doc_V1_Change()
            change.replica = replica
            change.seq = UInt64(index + 1)
            change.startCounter = 1_000_000 + UInt64(index)
            change.ops = [Ops.set(node, [RegisterPath([21, 1, 4])], values: values)]
            state.apply(change)
        }
        return state
    }

    @Test func tenThousandChangesOnEachSidePreviewWithinTheBudget() async throws {
        let items = (0..<Self.objects).map { index in
            DenseRectangles.Item(rect: Rect(x: Double(index % 80) * 30, y: Double(index / 80) * 30, width: 22, height: 22), fill: nil)
        }
        let base = try DenseRectangles.document(title: "Base", items).state
        let nodes = base.store.nodes.filter { base.store.kind($0) == 21 }.sorted()
        #expect(nodes.count == Self.objects)
        // The branch moves the first 1,500 objects, main the 1,000 from 1,000 on: 500 overlap.
        let branch = Self.advanced(base, nodes: nodes, replica: 0xB1, count: Self.changes, offset: 0, stride: 1_500)
        let main = Self.advanced(base, nodes: nodes, replica: 0xA1, count: Self.changes, offset: 1_000, stride: 1_000)

        let start = DispatchTime.now().uptimeNanoseconds
        let preview = await BranchMergeModel.preview(branch: branch, main: main)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        print("COLLAB-018 merge preview, 10,000 branch changes against 10,000 on main over \(Self.objects) objects: \(String(format: "%.3f", seconds)) s")
        // Every object either side moved differs (the branch's and main's last positions differ).
        #expect(preview.entries.count == 2_000)
        #expect(preview.entries.allSatisfy { $0.kind == .changed })
        PerfBudget.expect(.seconds(seconds), within: .seconds(Self.budget), "preview",
                          enforcedInDebug: "the app's tests build Debug only; a Debug figure within the budget is a Release one too")
    }
}
