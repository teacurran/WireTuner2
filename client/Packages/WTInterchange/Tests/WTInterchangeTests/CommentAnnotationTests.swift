// COLLAB-033: comment threads as PDF annotations -- one `/Text` annotation per open thread at its
// pin, replies threaded by `/IRT`, author and time, resolved threads left out; off by default and
// for PDF/X; the SVG, HTML, EPS and bitmap writers never write comments.

import CoreGraphics
import Foundation
import PDFKit
import Testing
import WTGeometry
@testable import WTInterchange
import WTRender

@Suite struct CommentAnnotationTests {
    /// 2026-01-02 03:04:05 UTC.
    static let time: Int64 = 1_767_323_045_000

    static let threads = [
        ExportCommentThread(pin: Point(x: 30, y: 40), comments: [
            ExportComment(author: "Priya", text: "Make the red warmer", wallTimeMs: time),
            ExportComment(author: "Sam", text: "Done \u{2014} check it?", wallTimeMs: time + 60_000),
            ExportComment(author: "Priya", text: "Perfect", wallTimeMs: time + 120_000),
        ]),
        ExportCommentThread(pin: Point(x: 150, y: 100), comments: [ExportComment(author: "Sam", text: "Rounder?", wallTimeMs: time)]),
        // Resolved, empty, and off the page: none of them is written.
        ExportCommentThread(pin: Point(x: 60, y: 60), resolved: true, comments: [ExportComment(author: "Sam", text: "Resolved", wallTimeMs: time)]),
        ExportCommentThread(pin: Point(x: 70, y: 70), comments: []),
        ExportCommentThread(pin: Point(x: 900, y: 70), comments: [ExportComment(author: "Sam", text: "Pasteboard", wallTimeMs: time)]),
    ]

    static func scene(comments: Bool) -> ExportScene {
        var scene = Corpus.scene([PDFInteractiveTests.page], nodes: PDFInteractiveTests.nodes)
        if comments { scene.comments = threads }
        return scene
    }

    static func annotations(_ data: Data) throws -> [PDFAnnotation] {
        try #require(PDFDocument(data: data)?.page(at: 0)).annotations.filter { $0.type == "Text" }
    }

    @Test func openThreadsBecomeThreadedTextAnnotations() throws {
        var options = PDFOptions()
        options.commentsAsAnnotations = true
        let data = try PDFExporter().data(scene: Self.scene(comments: true), options: options).data
        let comments = try Self.annotations(data)
        #expect(comments.map(\.contents) == ["Make the red warmer", "Done \u{2014} check it?", "Perfect", "Rounder?"])
        let opener = comments[0]
        // The pin (30, 40) on a 150 pt page is (30, 110) in PDF space: the icon's top-left.
        #expect(abs(opener.bounds.minX - 30) < 0.01 && abs(opener.bounds.maxY - 110) < 0.01)
        #expect(opener.userName == "Priya")
        #expect(comments[1].userName == "Sam" && comments[1].bounds == opener.bounds)
        let text = PDFTests.text(of: data)
        #expect(text.contains("/IRT") && text.contains("/RT /R"))
        #expect(text.contains("(D:20260102030405Z)") && text.contains("(D:20260102030505Z)"))
        #expect(!text.contains("Resolved") && !text.contains("Pasteboard"))
        // Replies point at their opener's object.
        let irt = try #require(text.range(of: #"/IRT (\d+) 0 R"#, options: .regularExpression)).lowerBound
        let reference = text[irt...].split(separator: " ")[1]
        #expect(text.contains("\n\(reference) 0 obj"))
        if QPDF.isAvailable {
            let check = try QPDF.check(data)
            #expect(check.status == 0, "\(check.output)")
        } else {
            #expect(CGPDFDocument(CGDataProvider(data: data as CFData)!)?.numberOfPages == 1)
        }
    }

    @Test func offByDefaultAndForPDFX() throws {
        #expect(PDFOptions().commentsAsAnnotations == false)
        let plain = try PDFExporter().data(scene: Self.scene(comments: true), options: PDFOptions()).data
        #expect(try Self.annotations(plain).isEmpty)
        var options = PDFOptions.printPDFX4
        options.commentsAsAnnotations = true
        let result = try PDFExporter().data(scene: Self.scene(comments: true), options: options)
        #expect(!PDFTests.text(of: result.data).contains("/Subtype /Text"))
        #expect(result.notes.contains { $0.contains("comment threads left out") })
    }

    @Test func otherWritersNeverWriteComments() throws {
        let with = Self.scene(comments: true), without = Self.scene(comments: false)
        let svg = { (scene: ExportScene) in SVGExporter().documents(scene: scene, options: .defaults).map(\.text) }
        #expect(svg(with) == svg(without))
        let html = { (scene: ExportScene) in try HTMLPublisher().publish(scene).files.map(\.data) }
        #expect(try html(with) == html(without))
        // The EPS header carries the creation time; everything else must match.
        let eps = { (scene: ExportScene) in
            String(decoding: try EPSExporter().data(scene: scene, page: 0, options: .defaults).data, as: UTF8.self)
                .split(separator: "\n").filter { !$0.hasPrefix("%%CreationDate") }
        }
        #expect(try eps(with) == eps(without))
        let png = { (scene: ExportScene) -> Data in
            let folder = Corpus.directory()
            let summary = try BitmapExporter(format: .png).export(scene: scene, options: PNGOptions(), to: ExportDestination(url: folder.appendingPathComponent("page.png")))
            return try Data(contentsOf: try #require(summary.files.first))
        }
        #expect(try png(with) == png(without))
    }
}
