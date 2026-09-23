package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.history.DocOps.BRUSHES;
import static com.villagecompute.wiretuner.api.history.DocOps.COMMENTS;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.PAGES;
import static com.villagecompute.wiretuner.api.history.DocOps.STYLES;
import static com.villagecompute.wiretuner.api.history.DocOps.SWATCHES;
import static com.villagecompute.wiretuner.api.history.DocOps.SYMBOLS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.util.List;
import java.util.Set;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.api.persistence.VersionRepository.VersionRow;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.OpId;
import com.villagecompute.wiretuner.crdt.Zstd;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.DocumentInfo;
import com.villagecompute.wiretuner.doc.v1.ElementDelete;
import com.villagecompute.wiretuner.doc.v1.ElementInsert;
import com.villagecompute.wiretuner.doc.v1.ElementMove;
import com.villagecompute.wiretuner.doc.v1.MoveNode;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.SetFields;
import com.villagecompute.wiretuner.doc.v1.SetRemove;
import com.villagecompute.wiretuner.doc.v1.TextDelete;
import com.villagecompute.wiretuner.doc.v1.TextMark;
import com.villagecompute.wiretuner.docs.v1.HistoryRow;
import com.villagecompute.wiretuner.docs.v1.ListHistoryResponse;
import com.villagecompute.wiretuner.docs.v1.Session;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;

/** SRV-007, SRV-011: the pure parts of the history package. */
class HistoryPartsTest {

    // ---------------------------------------------------------------------------- Cold segments

    @Test
    void aSegmentRoundTripsItsChangesInOrder() {
        Change big = Change.newBuilder().setReplica(7).setSeq(1).setLabel("x".repeat(300)).build();
        List<SequencedChange> changes = List.of(
                SequencedChange.newBuilder().setServerSeq(1).setChange(big).build(),
                SequencedChange.newBuilder().setServerSeq(2).setChange(big.toBuilder().setSeq(2).setLabel("y")).build());
        assertThat(SegmentCodec.decode(SegmentCodec.encode(changes))).isEqualTo(changes);
        assertThat(SegmentCodec.decode(SegmentCodec.encode(List.of()))).isEmpty();
    }

    @Test
    void anObjectThatIsNotASegmentIsRefused() {
        assertThatThrownBy(() -> SegmentCodec.decode(new byte[] {1, 2, 3}))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("no zstd content size");
        // A zstd frame whose content is not delimited changes: a length running past the end.
        assertThatThrownBy(() -> SegmentCodec.decode(Zstd.compress(new byte[] {10, 1})))
                .isInstanceOf(IllegalArgumentException.class).hasMessageContaining("not a cold segment");
    }

    // ---------------------------------------------------------------------------- Touched nodes

    @Test
    void everyOpNamesItsNodeACreateItsOwnIdANoopNone() {
        com.villagecompute.wiretuner.doc.v1.OpId n = DocOps.id(9, 3);
        DocOps.Author author = new DocOps.Author(5);
        Change change = author.change("All", DocOps.create(wellKnown(LAYERS), DocOps.path("A", "")), DocOps.rename(n, "B"),
                Op.newBuilder().setMove(MoveNode.newBuilder().setNode(n).setParent(wellKnown(LAYERS))).build(),
                DocOps.delete(n),
                Op.newBuilder().setElementInsert(ElementInsert.newBuilder().setNode(n).addPositions(ByteString.copyFrom(new byte[] {1}))
                        .addPositions(ByteString.copyFrom(new byte[] {2}))).build(),
                Op.newBuilder().setElementMove(ElementMove.newBuilder().setNode(n)).build(),
                Op.newBuilder().setElementDelete(ElementDelete.newBuilder().setNode(n)).build(),
                DocOps.type(n, "héllo"),
                Op.newBuilder().setTextDelete(TextDelete.newBuilder().setNode(n)).build(),
                Op.newBuilder().setTextMark(TextMark.newBuilder().setNode(n)).build(),
                DocOps.keyword("k"),
                Op.newBuilder().setSetRemove(SetRemove.newBuilder().setNode(n)).build(),
                DocOps.noop());
        List<TouchedNodes.Named> ops = TouchedNodes.ops(change);
        assertThat(ops.get(0).node()).isEqualTo(new OpId(1, 5));
        assertThat(ops.subList(1, 10)).allMatch(op -> op.node().equals(OpId.of(n)));
        assertThat(ops.get(10).node()).isEqualTo(OpId.wellKnown(DocOps.SETTINGS));
        assertThat(ops.get(12).node()).isNull();
        // The element insert takes two counters, the text insert five.
        assertThat(ops.get(5).id().counter()).isEqualTo(7);
        assertThat(ops.get(7).id().counter()).isEqualTo(9);
        assertThat(ops.get(8).id().counter()).isEqualTo(14);
        assertThat(TouchedNodes.of(change)).containsExactly(new OpId(1, 5), OpId.of(n), OpId.wellKnown(DocOps.SETTINGS));
    }

    @Test
    void excludedOpsBecomeNoopsOverTheSameCounters() {
        com.villagecompute.wiretuner.doc.v1.OpId n = DocOps.id(9, 3);
        DocOps.Author author = new DocOps.Author(5);
        Change change = author.change("Mixed", DocOps.type(n, "abc"), DocOps.rename(DocOps.id(4, 3), "kept"), DocOps.noop());
        assertThat(TouchedNodes.without(change, Set.of(new OpId(1, 1)))).isSameAs(change);
        Change filtered = TouchedNodes.without(change, Set.of(OpId.of(n)));
        assertThat(filtered.getOpsList()).hasSize(5);
        assertThat(filtered.getOpsList().subList(0, 3)).allMatch(Op::hasNoop);
        assertThat(filtered.getOps(3)).isEqualTo(change.getOps(1));
        assertThat(TouchedNodes.ops(filtered).get(3).id()).isEqualTo(TouchedNodes.ops(change).get(1).id());
    }

    // ---------------------------------------------------------------------------- Search record

    @Test
    void theSearchRecordHoldsLiveNamesNotesTextAndFileInfo() {
        DocOps.Author a = new DocOps.Author(11);
        Engine engine = new Engine();
        long seq = 0;
        com.villagecompute.wiretuner.doc.v1.OpId logo = a.next();
        engine.apply(a.change("Logo", DocOps.create(wellKnown(LAYERS), DocOps.path("Logotype v3", "Check the\nkerning"))), ++seq);
        engine.apply(a.change("Pages", DocOps.create(wellKnown(PAGES), DocOps.page("Cover"))), ++seq);
        engine.apply(a.change("Swatch", DocOps.create(wellKnown(SWATCHES), DocOps.swatch("Brand red"))), ++seq);
        engine.apply(a.change("Style", DocOps.create(wellKnown(STYLES), DocOps.style("Headline"))), ++seq);
        engine.apply(a.change("Symbol", DocOps.create(wellKnown(SYMBOLS), DocOps.symbol("Arrow"))), ++seq);
        engine.apply(a.change("Brush", DocOps.create(wellKnown(BRUSHES), DocOps.brush("Charcoal"))), ++seq);
        com.villagecompute.wiretuner.doc.v1.OpId story = a.next();
        engine.apply(a.change("Text", DocOps.create(wellKnown(LAYERS), DocOps.text(""))), ++seq);
        engine.apply(a.change("Type", DocOps.type(story, "Hello world\n\nSecond paragraph")), ++seq);
        com.villagecompute.wiretuner.doc.v1.OpId gone = a.next();
        engine.apply(a.change("Gone", DocOps.create(wellKnown(LAYERS), DocOps.path("Deleted thing", ""))), ++seq);
        com.villagecompute.wiretuner.doc.v1.OpId child = a.next();
        engine.apply(a.change("Child", DocOps.create(gone, DocOps.path("Child of deleted", ""))), ++seq);
        engine.apply(a.change("Delete", DocOps.delete(gone)), ++seq);
        engine.apply(a.change("Thread", DocOps.create(wellKnown(COMMENTS), DocOps.thread("A comment"))), ++seq);
        engine.apply(a.change("Info", DocOps.info("Spring catalogue", "Products\nfor 2026"), DocOps.keyword("brochure"),
                DocOps.keyword("print")), ++seq);
        com.villagecompute.wiretuner.doc.v1.OpId quiet = a.next();
        engine.apply(a.change("Quiet", DocOps.create(wellKnown(LAYERS), DocOps.path("Quiet", "a note")),
                DocOps.clearNote(quiet)), ++seq);
        engine.apply(a.change("Rename", DocOps.rename(logo, "Logotype v3")), ++seq);
        com.villagecompute.wiretuner.doc.v1.OpId back = a.next();
        engine.apply(a.change("Back", DocOps.create(wellKnown(LAYERS), DocOps.path("Restored", ""))), ++seq);
        engine.apply(a.change("Delete", DocOps.delete(back)), ++seq);
        engine.apply(a.change("Undelete", DocOps.undelete(back)), ++seq);

        SearchExtractor.Record record = SearchExtractor.extract(engine.store());
        assertThat(record.names().split("\n")).containsExactlyInAnyOrder("o:Logotype v3", "p:Cover", "s:Brand red",
                "st:Headline", "sy:Arrow", "o:Charcoal", "o:Quiet", "o:Restored", "k:Spring catalogue", "k:Products", "k:for 2026",
                "k:brochure", "k:print");
        assertThat(record.bodyText().split("\n")).containsExactlyInAnyOrder("n:Check the", "n:kerning", "t:Hello world",
                "t:Second paragraph");
        assertThat(SearchExtractor.live(engine.store(), OpId.of(child))).isFalse();
    }

    @Test
    void unparseableRecordsReadAsTheEmptyMessage() {
        assertThat(SearchExtractor.parse(new byte[] {(byte) 0xff}, CommonProps.getDefaultInstance()))
                .isSameAs(CommonProps.getDefaultInstance());
        assertThat(SearchExtractor.parse(DocumentInfo.newBuilder().setTitle("t").build().toByteArray(),
                DocumentInfo.getDefaultInstance()).getTitle()).isEqualTo("t");
        assertThat(SearchExtractor.extract(new Engine().store()).names()).isEmpty();
    }

    // ---------------------------------------------------------------------------- Timeline

    static History.Logged logged(long seq, String label, String user, String name, long micros, String branch) {
        return new History.Logged(seq, Change.newBuilder().setReplica(1).setSeq(seq).setStartCounter(seq).setLabel(label)
                .addOps(DocOps.rename(DocOps.id(1, 9), "x")).build(), micros,
                Participant.newBuilder().setUserId(user).setDisplayName(name).build(), branch, branch.isEmpty() ? "" : "B");
    }

    @Test
    void aQueryMatchesTheLabelTheAuthorOrANamedNode() {
        History.Logged row = logged(1, "Recolor logo", "u1", "Alice Example", 0, "");
        assertThat(History.matches(row, "logo", Set.of())).isTrue();
        assertThat(History.matches(row, "alice", Set.of())).isTrue();
        assertThat(History.matches(row, "bob", Set.of())).isFalse();
        assertThat(History.matches(row, "badge", Set.of(new OpId(1, 9)))).isTrue();
        assertThat(History.matches(row, "badge", Set.of(new OpId(2, 9)))).isFalse();
    }

    // ---------------------------------------------------------------------------- History index

    @Test
    void theIndexNamesTouchedNodesAndTheLastNameAChangeGivesEach() {
        DocOps.Author author = new DocOps.Author(5);
        com.villagecompute.wiretuner.doc.v1.OpId n = DocOps.id(9, 3);
        Change change = author.change("Index", DocOps.create(wellKnown(LAYERS), DocOps.path("Logo", "")),
                DocOps.create(wellKnown(LAYERS), NodeProps.getDefaultInstance()),
                DocOps.rename(n, "Badge"),
                Op.newBuilder().setSet(SetFields.newBuilder().setNode(n)
                        .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 1, CommonProps.NAME_FIELD_NUMBER))).build(),
                DocOps.clearNote(n),
                DocOps.noop());
        ChangeIndex.Entries entries = ChangeIndex.entries(change);
        assertThat(entries.nodes()).containsExactly(new OpId(1, 5), new OpId(2, 5), OpId.of(n));
        assertThat(entries.names()).containsExactly(
                new ChangeIndex.Named(new OpId(1, 5), NodeProps.PATH_FIELD_NUMBER, "Logo"),
                new ChangeIndex.Named(new OpId(2, 5), 0, ""),
                new ChangeIndex.Named(OpId.of(n), NodeProps.PATH_FIELD_NUMBER, ""));
        UUID document = UUID.randomUUID();
        io.vertx.mutiny.sqlclient.Tuple tuple = entries.tuple(document, 7);
        assertThat(tuple.size()).isEqualTo(8);
        assertThat(tuple.getValue(0)).isEqualTo(document);
        assertThat((Long[]) tuple.getValue(3)).containsExactly(1L, 2L, 9L);
        assertThat((String[]) tuple.getValue(7)).containsExactly("Logo", "", "");
        assertThat(ChangeIndex.kindName(NodeProps.MASTER_PAGE_FIELD_NUMBER)).isEqualTo("Master page");
        assertThat(ChangeIndex.kindName(0)).isEmpty();
    }

    @Test
    void attributesAreTheRegistersAChangeWrites() {
        com.villagecompute.wiretuner.doc.v1.OpId n = DocOps.id(9, 3);
        com.villagecompute.wiretuner.doc.v1.FieldPath points = DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 2);
        com.villagecompute.wiretuner.doc.v1.FieldPath element = points.toBuilder()
                .addSegments(com.villagecompute.wiretuner.doc.v1.PathSegment.newBuilder()
                        .setElement(com.villagecompute.wiretuner.doc.v1.ElementId.newBuilder().setCounter(4).setReplica(3)))
                .build();
        Change change = new DocOps.Author(5).change("All", DocOps.create(wellKnown(LAYERS), DocOps.path("A", "")),
                DocOps.rename(n, "B"), DocOps.clearNote(n),
                Op.newBuilder().setSet(SetFields.newBuilder().setNode(n)
                        .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 1))
                        .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 1, 999))
                        .addPaths(DocOps.fields(999, 1))
                        .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER))
                        .addPaths(com.villagecompute.wiretuner.doc.v1.FieldPath.getDefaultInstance())
                        .addPaths(DocOps.fields(NodeProps.PATH_FIELD_NUMBER, 999))
                        .addPaths(element.toBuilder().setSegments(1, element.getSegments(2)))).build(),
                Op.newBuilder().setMove(MoveNode.newBuilder().setNode(n).setParent(wellKnown(LAYERS))).build(),
                DocOps.delete(n),
                Op.newBuilder().setElementInsert(ElementInsert.newBuilder().setNode(n).setSequence(points)
                        .addPositions(ByteString.copyFrom(new byte[] {1}))).build(),
                Op.newBuilder().setElementMove(ElementMove.newBuilder().setNode(n).setElement(element)).build(),
                Op.newBuilder().setElementDelete(ElementDelete.newBuilder().setNode(n).addElements(element)).build(),
                DocOps.type(DocOps.id(10, 3), "x"),
                Op.newBuilder().setTextDelete(TextDelete.newBuilder().setNode(n)
                        .setText(DocOps.fields(NodeProps.TEXT_FIELD_NUMBER, 3))).build(),
                Op.newBuilder().setTextMark(TextMark.newBuilder().setNode(n)
                        .setText(DocOps.fields(NodeProps.TEXT_FIELD_NUMBER, 4))).build(),
                DocOps.keyword("k"),
                Op.newBuilder().setSetRemove(SetRemove.newBuilder().setNode(n)
                        .setSet(DocOps.fields(NodeProps.SETTINGS_FIELD_NUMBER, 5))).build(),
                DocOps.noop());
        List<String> attributes = ChangeIndex.attributes(change);
        assertThat(attributes).startsWith("Name", "Note", "Common", "Order", "Deleted");
        assertThat(attributes).contains("Text", "Info");
        assertThat(attributes).doesNotContain("");
        assertThat(ChangeIndex.display("stroke_width")).isEqualTo("Stroke width");
        List<Op> many = new java.util.ArrayList<>();
        for (int field = 1; field <= 40; field++) {
            many.add(Op.newBuilder().setSet(SetFields.newBuilder().setNode(n)
                    .addPaths(DocOps.fields(NodeProps.SETTINGS_FIELD_NUMBER, field))).build());
        }
        assertThat(ChangeIndex.attributes(new DocOps.Author(6).change("Many", many))).hasSizeLessThanOrEqualTo(32);
    }

    @Test
    void aSessionIsOneAuthorAndBranchWithShortGaps() {
        History.Logged newer = logged(2, "b", "u1", "A", History.SESSION_GAP_MICROS + 5, "");
        assertThat(History.sameSession(newer, logged(1, "a", "u1", "A", 10, ""))).isTrue();
        assertThat(History.sameSession(newer, logged(1, "a", "u1", "A", 0, ""))).isFalse();
        assertThat(History.sameSession(newer, logged(1, "a", "u2", "B", 10, ""))).isFalse();
        assertThat(History.sameSession(newer, logged(1, "a", "u1", "A", 10, UUID.randomUUID().toString()))).isFalse();
    }

    @Test
    void smallOrExpandedSessionsCarryTheirChanges() {
        List<History.Logged> big = List.of(logged(6, "f", "u", "A", 6, ""), logged(5, "e", "u", "A", 5, ""),
                logged(4, "d", "u", "A", 4, ""), logged(3, "c", "u", "A", 3, ""), logged(2, "b", "u", "A", 2, ""),
                logged(1, "a", "u", "A", 1, ""));
        Session session = History.session(big, 0);
        assertThat(session.getChangesList()).isEmpty();
        assertThat(session.getFirstServerSeq()).isEqualTo(1);
        assertThat(session.getLastServerSeq()).isEqualTo(6);
        assertThat(session.getChangeCount()).isEqualTo(6);
        assertThat(session.getNodeCount()).isEqualTo(1);
        assertThat(History.session(big, 1).getChangesList()).hasSize(6);
        assertThat(History.session(big.subList(0, 2), 0).getChangesList()).extracting(c -> c.getLabel()).containsExactly("f", "e");
    }

    static VersionRow version(long seq) {
        return new VersionRow(UUID.randomUUID(), UUID.randomUUID(), seq, "v" + seq, "", "", "", false, 0);
    }

    @Test
    void versionsInterleaveWithSessionsBySeq() {
        Session newer = Session.newBuilder().setFirstServerSeq(8).setLastServerSeq(10).build();
        Session older = Session.newBuilder().setFirstServerSeq(3).setLastServerSeq(5).build();
        ListHistoryResponse response = VersionGrpcService.timeline(List.of(newer, older),
                List.of(version(12), version(10), version(6), version(2)), 3, 1);
        assertThat(response.getRowsList()).extracting(row -> row.getRowCase() == HistoryRow.RowCase.VERSION
                ? "v" + row.getVersion().getServerSeq() : "s" + row.getSession().getLastServerSeq())
                .containsExactly("v12", "v10", "s10", "v6", "s5", "v2");
        assertThat(response.getNextCursor()).isNotEmpty();
        assertThat(response.getRetainedFromSeq()).isEqualTo(1);
        assertThat(VersionGrpcService.timeline(List.of(), List.of(), 0, 1).getNextCursor()).isEmpty();
    }

    // ---------------------------------------------------------------------------- Collecting

    @Test
    void aSnapshotIsCollectedOnlyAtAPublishedPoint() {
        DocOps.Author a = new DocOps.Author(3);
        Engine engine = new Engine();
        com.villagecompute.wiretuner.doc.v1.OpId node = a.next();
        engine.apply(a.change("Create", DocOps.create(wellKnown(LAYERS), DocOps.path("n", ""))), 1L);
        engine.apply(a.change("Delete", DocOps.delete(node)), 2L);
        Snapshotter.collect(engine, 0, 0);
        assertThat(engine.store().stableSeq()).isZero();
        Snapshotter.collect(engine, 2, Long.MAX_VALUE / 2);
        assertThat(engine.store().stableSeq()).isEqualTo(2);
        assertThat(engine.store().isCreated(OpId.of(node))).isFalse();
    }
}
