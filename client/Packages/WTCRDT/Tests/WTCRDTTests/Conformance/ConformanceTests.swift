import Foundation
import Testing

/// Replays every vector under crdt-conformance/vectors through WTCRDT (CRDT-011).  The Java twin
/// is server/conformance's ConformanceTest; both check the same committed hashes, which is what
/// proves the engines agree.
@Suite struct ConformanceTests {
    static let root = ConformanceRunner.vectorsRoot
    static let files = ConformanceRunner.vectors(root)

    @Test func theVectorDirectoryHoldsVectors() {
        #expect(!Self.files.isEmpty)
    }

    @Test(arguments: files)
    func everyVectorConverges(_ file: URL) throws {
        let outcome = try ConformanceRunner.run(Self.root, file)
        #expect(outcome.passed, "\(outcome.report)")
    }
}
