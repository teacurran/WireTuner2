import Foundation
import Testing
import WTCRDT
import WTGeometry
import WTInterchange
@testable import WTModel
import WTProto
import WTRender

/// A document's content with every id replaced by its position in a tree walk, so a copy made of
/// fresh ops reads the same as its source (IO-006: "a canonical read-out identical to the source").
enum CanonicalReadout {
    static func of(_ state: EngineState) -> [String] {
        let nodes = DocumentPackage.liveNodes(in: state)
        var nodeMap: [OpID: OpID] = [:]
        var elementMap: [OpID: OpID] = [:]
        for (index, node) in nodes.enumerated() where node.replica != 0 {
            nodeMap[node] = OpID(counter: UInt64(index + 1), replica: 1)
        }
        var ordinal: UInt64 = 1
        // Sequence elements in the order the merged props list them (sequence order, nested
        // sequences inside their element).
        func visit(_ bytes: [UInt8], _ message: String) {
            for field in WireReader.fields(bytes) ?? [] where field.wireType == 2 {
                guard let row = state.schema.field(message, Int(field.number)), row.type == "message" else { continue }
                if row.policy == .sequence, let id = WireReader.fields(field.payload)?.first.flatMap({ ReferenceRewriter.id($0.payload) }) {
                    elementMap[id] = OpID(counter: ordinal, replica: 2)
                    ordinal += 1
                }
                visit(field.payload, ReferenceRewriter.inner(row))
            }
        }
        for node in nodes {
            visit(Wire.bytes { try state.props(node).serializedBytes() }, Schema.root)
            for field in state.store.textPaths(node) {
                for char in state.store.text(node, field)?.liveChars ?? [] {
                    elementMap[char] = OpID(counter: ordinal, replica: 2)
                    ordinal += 1
                }
            }
        }
        let rewriter = ReferenceRewriter(schema: state.schema, nodes: nodeMap, elements: elementMap)
        var lines: [String] = []
        for node in [WellKnown.document] + nodes {
            let parent = state.store.placement(node).map { nodeMap[$0.parent] ?? $0.parent }
            var unresolved = false
            let props = rewriter.message(Wire.bytes { try state.props(node).serializedBytes() }, type: Schema.root, unresolved: &unresolved)
            lines.append("\(nodeMap[node] ?? node) in \(parent.map(\.description) ?? "-"): \(props)")
            for field in state.store.textPaths(node) {
                guard let text = state.store.text(node, field) else { continue }
                lines.append("  text \(field): \(text.string)")
                for mark in text.marks.values.sorted(by: { $0.value.lexicographicallyPrecedes($1.value) }) {
                    let start = elementMap[mark.start.char].map(\.description) ?? "end"
                    let end = elementMap[mark.end.char].map(\.description) ?? "end"
                    lines.append("  mark \(start)\(mark.start.before) \(end)\(mark.end.before) \(mark.value)")
                }
            }
            for path in state.store.setPaths(node) {
                lines.append("  set \(path): \(state.store.members(node, path))")
            }
        }
        return lines
    }
}

/// A document with a bit of everything the re-issue must carry.
enum PackageFixture {
    static let text = RegisterPath([130, 2])

    static func document() throws -> Replica {
        var a = Replica(0xA)
        let layers = try LayerFixture.layers(["One", "Two"], on: &a)
        try a.perform(PlaceImportedScene(ImportFixture.vector, placement: .at(Point(x: 10, y: 10)), layer: layers[0]))
        try a.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 0, y: 300)), layer: layers[1], link: ImportFixture.link))
        let animation = ImportedPlacedFile.Kind.svgAnimation(css: false, smil: true, script: false, durationMs: 0)
        try a.perform(PlaceImportedScene(ImportFixture.placed(animation, blob: ImportFixture.svg, name: "a.svg"), placement: .at(Point(x: 0, y: 0)),
                                         layer: layers[1], poster: ImportedPoster(blob: ImportFixture.poster, timeMs: 250)))
        // A closed path whose contour starts at its third point (an ElementId register).
        let path = PathFixture.ids(try a.perform(PathFixture.closed([(0, 0), (10, 0), (10, 10), (0, 10)])), in: a.state)
        let points = a.state.liveElements(path.node, PathFields.points(path.contour))
        var contour = Wiretuner_Doc_V1_Contour()
        contour.start = points[2].elementID
        try a.perform(OpsCommand("Start", ops: [Ops.set(path.node, [PathFields.start(path.contour)], values: PathEditing.contourValues(contour))]))
        // A path whose second contour is deleted: its points are left out with it.
        let twice = try a.perform(CreatePath(contours: [NewContour(closed: true, points: PathFixture.points([(0, 0), (4, 0), (4, 4)])),
                                                        NewContour(points: PathFixture.points([(9, 9), (12, 12)]))]))!.createdObjects[0]
        let contours = a.state.liveElements(twice, PathFields.contours)
        try a.perform(OpsCommand("Delete contour", ops: [Ops.elementDelete(twice, [PathFields.contour(contours[1])])]))
        // A register written and then cleared.
        let transform = RegisterPath([150, 1, 4])
        try a.perform(OpsCommand("Move", ops: [Ops.set(layers[1], [transform], values: Fixture.layer(tx: 5))]))
        try a.perform(OpsCommand("Clear", ops: [Ops.set(layers[1], [transform], values: Wiretuner_Doc_V1_NodeProps())]))
        #expect(a.state.store.register(layers[1], transform)?.value == nil)
        // A deleted point and a deleted object are left out.
        try a.perform(OpsCommand("Delete point", ops: [Ops.elementDelete(path.node, [PathFields.point(path.contour, points[1])])]))
        let doomed = try a.perform(PathFixture.open([(0, 0), (5, 5)]))!.createdObjects[0]
        try a.perform(CutObjects([doomed]))
        // Text: delete the "e"s of "there"; mark a paragraph on the newline.
        let words = try #require(DocumentPackage.liveNodes(in: a.state).first { a.state.props($0).text.common.name == "Words" })
        let sequence = try #require(a.state.store.text(words, text))
        let chars = sequence.liveChars
        try a.perform(OpsCommand("Delete", ops: [Ops.textDelete(words, text, first: chars[5], count: 1)]))
        var paragraph = Wiretuner_Doc_V1_NodeProps()
        var newline = Wiretuner_Doc_V1_TextChar()
        newline.id = chars[2].elementID
        newline.paragraph.alignment = .center
        paragraph.text.text.chars = [newline]
        try a.perform(OpsCommand("Centre", ops: [Ops.set(words, [text.element(chars[2]).child(6).child(1)], values: paragraph)]))
        // Keywords, a SET on the settings node.
        var keywords = Wiretuner_Doc_V1_NodeProps()
        keywords.settings.info.keywords = ["alpha", "beta"]
        try a.perform(OpsCommand("Keywords", ops: [Ops.setAdd(WellKnown.settings, RegisterPath([2, 130, 4]), values: keywords)]))
        var unit = Wiretuner_Doc_V1_NodeProps()
        unit.settings.common.name = "Settings"
        try a.perform(OpsCommand("Name", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 1, 1])], values: unit)]))
        return a
    }

    /// `state` re-issued into a fresh replica, chunk by chunk.
    static func reissue(_ state: EngineState, into replica: UInt64, missing: [PackageBlobReference] = [], maxOps: Int = PackageReissue.maxOps,
                        maxBytes: Int = PackageReissue.maxBytes) throws -> (Replica, [Wiretuner_Doc_V1_Change]) {
        var copy = Replica(replica)
        let plan = try PackageReissue(state, missing: missing, maxOps: maxOps, maxBytes: maxBytes)
        var changes: [Wiretuner_Doc_V1_Change] = []
        while !plan.isFinished {
            changes.append(try #require(try copy.perform(plan.nextChunk())))
        }
        return (copy, changes)
    }
}

@Suite struct PackageReissueTests {
    @Test func exportThenImportReadsTheSameAsTheSource() throws {
        let source = try PackageFixture.document()
        let info = DocumentPackage.Info(documentID: "0190a1b2-0000-7000-8000-000000000001", title: "Poster", exportedBy: "user", exportedByName: "Me",
                                        appVersion: "0.1.0/1", headServerSeq: 7, unsyncedChanges: 3, exportedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let contents = DocumentPackage.contents(of: source.state, info: info, page: Rect(x: 0, y: 0, width: 612, height: 792)) { hash in
            hash == ImportFixture.png.sha256 ? ImportFixture.png.data : nil
        }
        #expect(contents.manifest.title == "Poster" && contents.manifest.unsyncedChanges == 3 && contents.manifest.headServerSeq == 7)
        #expect(contents.manifest.exportedAtMs == 1_700_000_000_000)
        #expect(contents.manifest.featureLevel == DocumentPackage.featureLevel)
        #expect(contents.blobs.map(\.sha256) == [ImportFixture.png.sha256, ImportFixture.svg.sha256, ImportFixture.poster.sha256])
        let written = try PackageWriter().data(contents)
        #expect(written.summary.manifest.missingBlobs.count == 2)
        let opened = try DocumentPackage.reader.open(written.data)
        let state = try DocumentPackage.state(of: opened)
        #expect(state.stateHash == source.state.stateHash)

        let missing = opened.manifest.missingBlobs.map(PackageBlobReference.init)
        let (copy, changes) = try PackageFixture.reissue(state, into: 0xC, missing: missing)
        #expect(changes.count == 1 && changes[0].label == "Import package")
        #expect(CanonicalReadout.of(copy.state) == CanonicalReadout.of(source.state))
        let sourceIDs = Set(source.state.store.nodes.filter { $0.replica != 0 })
        #expect(copy.state.store.nodes.allSatisfy { !sourceIDs.contains($0) })
        #expect(changes.allSatisfy { $0.replica == 0xC })
    }

    @Test func twoImportsOfOnePackageAreUnrelated() throws {
        let source = try PackageFixture.document()
        let (one, _) = try PackageFixture.reissue(source.state, into: 0xC)
        let (two, _) = try PackageFixture.reissue(source.state, into: 0xD)
        #expect(Set(one.state.store.nodes.filter { $0.replica != 0 }).isDisjoint(with: two.state.store.nodes.filter { $0.replica != 0 }))
        #expect(CanonicalReadout.of(one.state) == CanonicalReadout.of(two.state))
    }

    @Test func largeDocumentsAreCutIntoChanges() throws {
        let source = try PackageFixture.document()
        let (byOps, opChanges) = try PackageFixture.reissue(source.state, into: 0xC, maxOps: 3)
        #expect(opChanges.count > 3)
        #expect(CanonicalReadout.of(byOps.state) == CanonicalReadout.of(source.state))
        let (byBytes, byteChanges) = try PackageFixture.reissue(source.state, into: 0xD, maxBytes: 64)
        #expect(byteChanges.count > 3)
        #expect(CanonicalReadout.of(byBytes.state) == CanonicalReadout.of(source.state))
        let plan = try PackageReissue(source.state)
        #expect(plan.copy(of: source.state.liveChildren(WellKnown.layers)[0]) == nil)
        var copy = Replica(0xE)
        try copy.perform(plan.nextChunk())
        #expect(plan.copy(of: source.state.liveChildren(WellKnown.layers)[0]) != nil)
    }

    @Test func missingBlobsBecomePlaceholderAssets() throws {
        let source = try PackageFixture.document()
        let orphan = Data(repeating: 7, count: 32)
        let missing = [
            PackageBlobReference(sha256: ImportFixture.png.sha256, size: 7, mediaType: "image/png", name: "photo.png"),
            PackageBlobReference(sha256: orphan, size: 9, mediaType: "font/otf", name: "Face.otf"),
        ]
        let (copy, _) = try PackageFixture.reissue(source.state, into: 0xC, missing: missing)
        let assets = copy.state.liveChildren(WellKnown.assets).map { copy.state.props($0).asset }
        #expect(assets.filter { $0.sha256 == ImportFixture.png.sha256 }.count == 1, "an asset already carries it")
        let placeholder = try #require(assets.first { $0.sha256 == orphan })
        #expect(placeholder.common.name == "Face.otf" && placeholder.byteSize == 9 && placeholder.mediaType == "font/otf")
        #expect(placeholder.common.note == "Missing from the package")
        #expect(PackageBlobReference(PackageBlob(sha256: orphan, size: 1, mediaType: "a/b", name: "n")).name == "n")
    }

    @Test func marksWhoseTextIsGoneAreDroppedAndEmptyTextsSkipped() throws {
        var a = Replica(0xA)
        let layer = try LayerFixture.layers(["One"], on: &a)[0]
        let text = ImportedText(runs: [
            ImportedTextRun(text: "ab", fontName: "Helvetica", fontSize: 10, origin: Point(x: 0, y: 0)),
            ImportedTextRun(text: "cd", fontName: "Courier", fontSize: 10, origin: Point(x: 20, y: 0)),
        ], name: "T")
        let empty = ImportedText(runs: [ImportedTextRun(text: "x", fontName: "Helvetica", fontSize: 10, origin: Point(x: 0, y: 0))], name: "E")
        let scene = ImportedScene(kind: .vector, name: "t.pdf", bounds: Rect(x: 0, y: 0, width: 10, height: 10), nodes: [.text(text), .text(empty)])
        let group = try ImportMappingTests.placed(a.perform(PlaceImportedScene(scene, placement: .at(Point(x: 0, y: 0)), layer: layer)), a)
        let nodes = a.state.liveChildren(group)
        let chars = try #require(a.state.store.text(nodes[0], PackageFixture.text)).liveChars
        let lone = try #require(a.state.store.text(nodes[1], PackageFixture.text)).liveChars
        try a.perform(OpsCommand("Delete", ops: [Ops.textDelete(nodes[0], PackageFixture.text, first: chars[0], count: 2),
                                                 Ops.textDelete(nodes[1], PackageFixture.text, first: lone[0], count: 1)]))
        let (copy, _) = try PackageFixture.reissue(a.state, into: 0xC)
        let copies = copy.state.liveChildren(copy.state.liveChildren(copy.state.liveChildren(WellKnown.layers)[0])[0])
        let kept = try #require(copy.state.store.text(copies[0], PackageFixture.text))
        #expect(kept.string == "cd")
        // "ab"'s marks lost every character; "cd"'s (family, style, size, fill) survive.
        #expect(try #require(a.state.store.text(nodes[0], PackageFixture.text)).marks.count == 8)
        #expect(kept.marks.count == 4)
        #expect(copy.state.store.text(copies[1], PackageFixture.text) == nil)
    }

    @Test func localOnlyRegistersStayBehind() throws {
        var a = Replica(0xA)
        var view = Wiretuner_Doc_V1_NodeProps()
        view.settings.view.magnification = 2
        view.settings.common.name = "S"
        try a.perform(OpsCommand("View", ops: [Ops.set(WellKnown.settings, [RegisterPath([2, 40, 1]), RegisterPath([2, 1, 1])], values: view)]))
        #expect(a.state.props(WellKnown.settings).settings.view.magnification == 2)
        let (copy, _) = try PackageFixture.reissue(a.state, into: 0xC)
        #expect(copy.state.props(WellKnown.settings).settings.common.name == "S")
        #expect(!copy.state.props(WellKnown.settings).settings.hasView)
    }

    @Test func referencesAndMembersAreRewritten() {
        let old = OpID(counter: 5, replica: 0xA)
        let new = OpID(counter: 9, replica: 0xC)
        let rewriter = ReferenceRewriter(schema: .generated, nodes: [old: new], elements: [old: new], reissued: [OpID(counter: 6, replica: 0xA)])
        // A NodeRef to a node left behind is cleared; one to a well-known node is kept.
        var ref = Wiretuner_Doc_V1_NodeRef()
        ref.id = OpID(counter: 77, replica: 0xA).proto
        ref.cached = Data([1])
        var unresolved = false
        let cleared = rewriter.message(Wire.bytes { try ref.serializedBytes() }, type: ReferenceRewriter.nodeRef, unresolved: &unresolved)
        #expect((try? Wiretuner_Doc_V1_NodeRef(serializedBytes: cleared))?.hasID == false)
        ref.id = WellKnown.layers.proto
        let kept = rewriter.message(Wire.bytes { try ref.serializedBytes() }, type: ReferenceRewriter.nodeRef, unresolved: &unresolved)
        #expect((try? Wiretuner_Doc_V1_NodeRef(serializedBytes: kept))?.id == WellKnown.layers.proto)
        #expect(!unresolved)
        // An element that will be re-issued later is unresolved; one that never will is kept.
        _ = rewriter.message(Wire.bytes { try OpID(counter: 6, replica: 0xA).proto.serializedBytes() }, type: ReferenceRewriter.elementID, unresolved: &unresolved)
        #expect(unresolved)
        #expect(rewriter.message([0xFF], type: ReferenceRewriter.elementID, unresolved: &unresolved) == [0xFF])
        #expect(rewriter.message([0xFF], type: ReferenceRewriter.nodeRef, unresolved: &unresolved) == [0xFF])
        #expect(rewriter.message([0xFF], type: "wiretuner.doc.v1.ColorRef", unresolved: &unresolved) == [0xFF])
        // SET members: ids, strings and scalars.
        let idRow = Schema.FieldPolicy(fieldNumber: 3, name: "points", policy: .set, onDangling: .unset, localOnly: false, type: "message",
                                       repeated: true, typeName: ReferenceRewriter.elementID, elementMessage: nil, oneof: nil)
        let member = [UInt8](repeating: 0, count: 7) + [5] + [UInt8](repeating: 0, count: 7) + [0xA]
        #expect(rewriter.member(member, row: idRow) == Wire.field(3, Wire.elementID(new)))
        let nodeRow = Schema.FieldPolicy(fieldNumber: 3, name: "n", policy: .set, onDangling: .unset, localOnly: false, type: "message",
                                         repeated: true, typeName: "wiretuner.doc.v1.OpId", elementMessage: nil, oneof: nil)
        #expect(rewriter.member(member, row: nodeRow) == Wire.field(3, Wire.elementID(new)))
        let unknown = [UInt8](repeating: 0, count: 7) + [8] + [UInt8](repeating: 0, count: 7) + [0xA]
        #expect(rewriter.member(unknown, row: nodeRow) == Wire.field(3, Wire.elementID(OpID(counter: 8, replica: 0xA))))
        let stringRow = Schema.FieldPolicy(fieldNumber: 4, name: "k", policy: .set, onDangling: .unset, localOnly: false, type: "string",
                                           repeated: true, typeName: nil, elementMessage: nil, oneof: nil)
        #expect(rewriter.member(Array("a".utf8), row: stringRow) == Wire.field(4, Array("a".utf8)))
        func scalar(_ type: String) -> Schema.FieldPolicy {
            Schema.FieldPolicy(fieldNumber: 2, name: "s", policy: .set, onDangling: .unset, localOnly: false, type: type, repeated: true,
                               typeName: nil, elementMessage: nil, oneof: nil)
        }
        #expect(rewriter.member([UInt8](repeating: 1, count: 8), row: scalar("fixed64")) == [0x11] + [UInt8](repeating: 1, count: 8))
        #expect(rewriter.member([1, 2, 3, 4], row: scalar("fixed32")) == [0x15, 1, 2, 3, 4])
        #expect(rewriter.member([0, 0, 0, 0, 0, 0, 0, 0, 0, 3], row: scalar("uint64")) == [0x10, 0])
        #expect(rewriter.member([3], row: scalar("uint32")) == [0x10, 3])
        // A path through an element left out has no copy; an unknown field has no row.
        #expect(rewriter.path(RegisterPath([20, 2]).element(OpID(counter: 1, replica: 1))) == nil)
        #expect(rewriter.row(at: RegisterPath([20, 999])) == nil)
        #expect(rewriter.row(at: RegisterPath([2, 40, 1])) == nil, "local_only")
        #expect(rewriter.record([0xFF], row: idRow, unresolved: &unresolved) == [0xFF])
    }

    @Test func damagedSnapshotsAreRefused() throws {
        func opened(snapshot: [UInt8], hash: Data = Data()) throws -> OpenedPackage {
            var manifest = PackageManifest()
            manifest.featureLevel = 1
            manifest.stateHash = hash
            let contents = PackageContents(manifest: manifest, snapshot: Data(snapshot), firstPage: ExportScene(pages: [
                ExportPage(bounds: Rect(x: 0, y: 0, width: 10, height: 10), displayList: DisplayList(canvas: CanvasID("t"), items: [])),
            ]))
            return try DocumentPackage.reader.open(PackageWriter().data(contents).data)
        }
        let notZstd = try opened(snapshot: [1, 2, 3, 4, 5, 6, 7])
        #expect(throws: DocumentPackage.ReadError.self) { try DocumentPackage.state(of: notZstd) }
        let garbage = try opened(snapshot: Zstd.compress([9, 9, 9, 9]))
        #expect(throws: DocumentPackage.ReadError.self) { try DocumentPackage.state(of: garbage) }
        let good = Snapshot.encode(EngineState())
        let mismatched = try opened(snapshot: Zstd.compress(good), hash: Data(repeating: 1, count: 32))
        #expect(throws: DocumentPackage.ReadError.self) { try DocumentPackage.state(of: mismatched) }
        let truncated = try opened(snapshot: Array(Zstd.compress(good + good + good).dropLast(3)))
        #expect(throws: DocumentPackage.ReadError.self) { try DocumentPackage.state(of: truncated) }
        // A node's name changed after the snapshot was hashed: the decode's own check refuses it.
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["Layer Alpha"], on: &a)
        var tampered = Snapshot.encode(a.state)
        let name = Array("Alpha".utf8)
        let at = try #require((0...(tampered.count - name.count)).first { Array(tampered[$0..<($0 + name.count)]) == name })
        tampered[at] = UInt8(ascii: "B")
        let decodeFails = try opened(snapshot: Zstd.compress(tampered))
        #expect(throws: DocumentPackage.ReadError.self) { try DocumentPackage.state(of: decodeFails) }
        #expect(DocumentPackage.ReadError.snapshot("x").description.contains("damaged"))
        #expect(try DocumentPackage.state(of: try opened(snapshot: Zstd.compress(good))).store.nodes.isEmpty)
    }

    @Test func zstdFrameHeadersGiveTheContentSize() {
        let magic: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
        #expect(ZstdFrame.contentSize(magic + [0x20, 42]) == 42, "single segment, one-byte size")
        #expect(ZstdFrame.contentSize(magic + [0x40, 0x50, 1, 0]) == 256 + 1, "window byte, two-byte size")
        #expect(ZstdFrame.contentSize(magic + [0xA1, 0x07, 0, 1, 0, 0]) == 256, "dictionary byte, four-byte size")
        #expect(ZstdFrame.contentSize(magic + [0xE0, 1, 0, 0, 0, 0, 0, 0, 0]) == 1)
        #expect(ZstdFrame.contentSize(magic + [0xE0, 0, 0, 0, 0, 0, 0, 0, 0x80]) == nil, "beyond Int")
        #expect(ZstdFrame.contentSize(magic + [0x00, 0]) == nil, "size not recorded")
        #expect(ZstdFrame.contentSize(magic + [0x80, 0, 1]) == nil, "truncated")
        #expect(ZstdFrame.contentSize([0, 1, 2, 3, 4, 5]) == nil)
        #expect(ZstdFrame.contentSize(Zstd.compress([UInt8](repeating: 3, count: 5000))) == 5000)
    }

    @Test func referencedBlobsCoverImagesPlacedFilesAndAssets() throws {
        var a = Replica(0xA)
        _ = try LayerFixture.layers(["One"], on: &a)
        try a.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 0, y: 0))))
        try a.perform(PlaceImportedScene(ImportFixture.bitmap, placement: .at(Point(x: 9, y: 0))))
        var props = Wiretuner_Doc_V1_NodeProps()
        props.placedFile.content.format = .eps
        props.placedFile.content.blobSha256 = ImportFixture.eps.sha256
        props.placedFile.content.previewSha256 = ImportFixture.poster.sha256
        props.placedFile.content.sourceName = "x.eps"
        var asset = Wiretuner_Doc_V1_NodeProps()
        asset.asset.sha256 = ImportFixture.svg.sha256
        let layer = a.state.liveChildren(WellKnown.layers)[0]
        try a.perform(OpsCommand("Placed", ops: [Ops.create(parent: layer, position: [0xF0], props: props),
                                                 Ops.create(parent: WellKnown.assets, position: [0xF0], props: asset)]))
        let references = DocumentPackage.referencedBlobs(in: a.state)
        #expect(references.map(\.mediaType) == ["image/png", "application/postscript", "image/png", "application/octet-stream"])
        #expect(references.map(\.sha256) == [ImportFixture.png.sha256, ImportFixture.eps.sha256, ImportFixture.poster.sha256, ImportFixture.svg.sha256])
        #expect(DocumentPackage.mediaType(uti: "no.such.type") == "application/octet-stream")
    }
}
