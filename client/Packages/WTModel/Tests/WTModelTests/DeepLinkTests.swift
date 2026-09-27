import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTRender
@testable import WTModel

/// COLLAB-038: deep links (inspect.adoc, "Data model") and where opening one lands.
@Suite struct DeepLinkTests {
    static let doc = "0190f3a2-4b7c-7d8e-9f01-23456789abcd"

    @Test func linksFormatAndParseEveryForm() throws {
        let node = OpID(counter: 42, replica: UInt64.max)
        let link = DeepLink(documentID: Self.doc, target: .node(node))
        #expect(link.description == "wiretuner://doc/\(Self.doc)/node/42-18446744073709551615")
        #expect(DeepLink(url: link.url) == link && link.node == node)
        let thread = DeepLink(documentID: Self.doc, target: .thread(OpID(counter: 7, replica: 3)))
        #expect(thread.url.absoluteString == "wiretuner://doc/\(Self.doc)/thread/7-3" && DeepLink(url: thread.url) == thread)
        let document = DeepLink(documentID: Self.doc)
        #expect(document.url.absoluteString == "wiretuner://doc/\(Self.doc)" && DeepLink(url: document.url) == document && document.node == nil)
        // The web form.
        #expect(link.webURL(host: "wiretuner.app")?.absoluteString == "https://wiretuner.app/d/\(Self.doc)/n/42-18446744073709551615")
        #expect(thread.webURL(host: "wiretuner.app")?.absoluteString == "https://wiretuner.app/d/\(Self.doc)/t/7-3")
        #expect(document.webURL(host: "wiretuner.app")?.absoluteString == "https://wiretuner.app/d/\(Self.doc)")
        for web in [link, thread, document] {
            #expect(DeepLink(url: try #require(web.webURL(host: "api.example.com"))) == web)
        }
        // The Comments panel's link as first built.
        #expect(DeepLink(url: URL(string: "wiretuner://document/doc-1?thread=5.9")!) == DeepLink(documentID: "doc-1", target: .thread(OpID(counter: 5, replica: 9))))
        #expect(DeepLink(url: URL(string: "wiretuner://document/doc-1")!) == DeepLink(documentID: "doc-1"))
    }

    @Test func otherURLsAreNotLinks() {
        for text in ["wiretuner://invite/abc", "wiretuner://auth/callback?code=c", "wiretuner://doc", "wiretuner://doc/a/b",
                     "wiretuner://doc/a/node/1", "wiretuner://doc/a/node/x-1", "wiretuner://doc/a/node/-1-2", "wiretuner://doc/a/page/1-2",
                     "wiretuner://doc/a%20b", "wiretuner://doc/a/node/1-2/extra", "https://wiretuner.app/i/token", "https://wiretuner.app/d",
                     "mailto:x@example.com", "wiretuner://document/a/b", "https://wiretuner.app/d/a/n/18446744073709551616-1", "file:///tmp/x"] {
            #expect(DeepLink(url: URL(string: text)!) == nil, "\(text)")
        }
        #expect(DeepLink.parse(id: "1-2") == OpID(counter: 1, replica: 2) && DeepLink.parse(id: "1.2", separator: ".") != nil)
        #expect(DeepLink.parse(id: "1-") == nil && DeepLink.parse(id: "１-2") == nil)
        #expect(!DeepLink.isDocumentID("") && !DeepLink.isDocumentID(String(repeating: "a", count: 129)))
    }

    @Test func whereALinkLands() throws {
        var a = Replica(1)
        let shape = try #require(try a.perform(CreateShape(.rectangle(CornerRadii()), size: Size(width: 10, height: 10), transform: .identity))).createdObjects[0]
        let gone = try #require(try a.perform(CreateShape(.ellipse, size: Size(width: 10, height: 10), transform: .identity))).createdObjects[0]
        try a.perform(CutObjects([gone]))
        let thread = try #require(try a.perform(CreateThread(at: Point(x: 1, y: 1), on: shape, author: "u", body: CommentBody("Hi"), postedAt: Date(), in: a.state)))
            .createdNodes[0]
        let state = a.state
        func land(_ target: DeepLink.Target, caughtUp: Bool = true) -> DeepLinkLanding {
            DeepLinkLanding.decide(DeepLink(documentID: "d", target: target), in: state, caughtUp: caughtUp)
        }
        #expect(land(.document, caughtUp: false) == .document)
        #expect(land(.node(shape), caughtUp: false) == .wait)
        #expect(land(.node(shape)) == .select(shape))
        #expect(land(.node(gone)) == .deleted(gone))
        let unknown = OpID(counter: 9999, replica: 77)
        #expect(land(.node(unknown)) == .notReceived(unknown))
        #expect(land(.thread(thread)) == .openThread(thread))
        #expect(land(.thread(shape)) == .deleted(shape))
    }
}
