import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTRender

/// import-formats.adoc, "Client", *Nesting*: an imported tree as deep as the importers let one
/// be (`ImportNesting` limit, 128 groups) opens as a document and is placed into one on a stack
/// the size of the main thread's (8 MB), where the app turns imported trees into nodes, and its
/// document draws there.
@Suite struct ImportNestingDepthTests {
    /// The deepest group nesting an importer produces.
    static let levels = 128

    final class Outcome<T>: @unchecked Sendable {
        var value: Result<T, Error>?
    }

    /// `body` run on a thread with the main thread's 8 MB stack, waited for.
    static func onMainSizedStack<T>(_ body: @escaping () throws -> T) throws -> T {
        let outcome = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) let work = body
        let thread = Thread {
            outcome.value = Result { try work() }
            done.signal()
        }
        thread.stackSize = 8 << 20
        thread.start()
        done.wait()
        return try outcome.value!.get()
    }

    static var deep: ImportedNode {
        let box = ImportedContour(start: .zero, segments: [.line(to: Point(x: 10, y: 0)), .line(to: Point(x: 10, y: 10))], closed: true)
        var node = ImportedNode.path(ImportedPath(contours: [box], fill: .solid(.black)))
        for level in 0..<levels {
            let clip = level % 2 == 0 ? ImportedPath(contours: [box]) : nil
            node = .group(ImportedGroup(children: [node], clip: clip, name: "g\(level)"))
        }
        return node
    }

    @Test func aTreeAsDeepAsImportersMakeOpensPlacesAndDraws() throws {
        let node = Self.deep
        let objects = try Self.onMainSizedStack { () -> Int in
            let document = ImportedDocument(format: .pdf, name: "deep.pdf", pages: [ImportedPage(size: Size(width: 100, height: 100), nodes: [node])])
            let core = try DocumentCreation.newDocument(from: .imported(DocumentImport(document)), replica: 0xA)
            var builder = DocumentDisplayListBuilder(canvas: "deep")
            _ = builder.outputDisplayList(core.state)
            var replica = try SwatchTests.document()
            let layer = try LayerFixture.layers(["Art"], on: &replica)[0]
            let scene = ImportedScene(kind: .vector, name: "deep.pdf", bounds: Rect(x: 0, y: 0, width: 100, height: 100), nodes: [node])
            try replica.perform(PlaceImportedScene(scene, placement: .at(.zero), layer: layer))
            return document.objectCount
        }
        #expect(objects == Self.levels + 1)
    }
}
