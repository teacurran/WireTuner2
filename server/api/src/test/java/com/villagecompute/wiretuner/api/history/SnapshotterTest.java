package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.PAGES;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Clock;
import java.time.Instant;
import java.time.ZoneOffset;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.Schema;
import com.villagecompute.wiretuner.crdt.SnapshotTransfer;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.doc.v1.SnapshotFrame;
import com.villagecompute.wiretuner.docs.v1.SearchField;
import com.villagecompute.wiretuner.docs.v1.SearchRequest;
import com.villagecompute.wiretuner.docs.v1.SearchResponse;
import com.villagecompute.wiretuner.sync.v1.FetchSnapshotRequest;
import com.villagecompute.wiretuner.sync.v1.FetchSnapshotResponse;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/** SRV-007: the snapshotter builds snapshots equal to a client's state and rewrites the search record. */
@QuarkusTest
class SnapshotterTest extends HistoryTestSupport {

    @Inject
    Snapshotter snapshotter;

    /** A document's changes: named objects, a page, a text block, file info. */
    List<Change> catalogue(DocOps.Author a) {
        List<Change> changes = new ArrayList<>();
        changes.add(a.change("Page", DocOps.create(wellKnown(PAGES), DocOps.page("Cover"))));
        changes.add(a.change("Logo", DocOps.create(wellKnown(LAYERS), DocOps.path("Logotype v3", "Kerning to check"))));
        OpId story = a.next();
        changes.add(a.change("Text", DocOps.create(wellKnown(LAYERS), DocOps.text("Intro"))));
        changes.add(a.change("Type", DocOps.type(story, "Autumn harvest sale\nEverything must go")));
        changes.add(a.change("Info", DocOps.info("Autumn catalogue", ""), DocOps.keyword("brochure")));
        return changes;
    }

    List<FetchSnapshotResponse> frames(UUID document) {
        List<FetchSnapshotResponse> frames = new ArrayList<>();
        Iterator<FetchSnapshotResponse> stream = blocking(ALICE, null).fetchSnapshot(FetchSnapshotRequest.newBuilder()
                .setDocumentId(document.toString()).build());
        stream.forEachRemaining(frames::add);
        return frames;
    }

    @Test
    void aSnapshotEqualsTheClientsStateAndCarriesTheSearchRecord() throws Exception {
        UUID doc = document(ALICE);
        DocOps.Author a = new DocOps.Author(replicaId());
        List<Change> changes = catalogue(a);
        long head = push(ALICE, null, doc, changes.toArray(Change[]::new));
        exec("UPDATE document SET snapshot_due_at = now() WHERE id = ?", doc);

        assertThat(run(() -> snapshotter.snapshot(doc))).isEqualTo(head);
        String hash = replayHash(changes);
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = ?", doc, head)).isEqualTo(hash);
        assertThat(value("SELECT snapshot_due_at FROM document WHERE id = ?", doc)).isNull();

        // FetchSnapshot serves it: the frames decode to the same state, the header gives the decompressed size.
        List<FetchSnapshotResponse> frames = frames(doc);
        List<SnapshotFrame> snapshot = frames.stream().map(FetchSnapshotResponse::getFrame).toList();
        assertThat(frames.get(0).getFrame().getHeader().getUncompressedSize())
                .isEqualTo(value("SELECT uncompressed_size FROM snapshot WHERE document_id = ?", doc));
        assertThat(StateHash.hex(SnapshotTransfer.state(snapshot, Schema.generated()).stateHash())).isEqualTo(hash);

        // The search record: every named node and every text block's plain text, with their prefixes.
        assertThat((String) value("SELECT names FROM document_search WHERE document_id = ?", doc))
                .contains("p:Cover", "o:Logotype v3", "o:Intro", "k:Autumn catalogue", "k:brochure");
        assertThat((String) value("SELECT body_text FROM document_search WHERE document_id = ?", doc))
                .contains("t:Autumn harvest sale", "t:Everything must go", "n:Kerning to check");
        SearchResponse found = TestUsers.as(docs, ALICE).search(SearchRequest.newBuilder().setSpaceId(alice.toString())
                .setQuery("harvest").build());
        assertThat(found.getHitsList()).anySatisfy(hit -> {
            assertThat(hit.getDocumentId()).isEqualTo(doc.toString());
            assertThat(hit.getMatchesList()).anyMatch(m -> m.getField() == SearchField.SEARCH_FIELD_TEXT);
        });

        // More changes: the next snapshot starts from this one and replays only the tail.
        Change more = a.change("Another", DocOps.create(wellKnown(LAYERS), DocOps.path("Badge", "")));
        changes.add(more);
        long next = push(ALICE, null, doc, more);
        assertThat(run(() -> snapshotter.snapshot(doc))).isEqualTo(next);
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = ?", doc, next))
                .isEqualTo(replayHash(changes));
        // A snapshot at a seq already recorded is left as it is.
        assertThat(run(() -> snapshotter.snapshot(doc))).isEqualTo(next);
        assertThat(count("SELECT count(*) FROM snapshot WHERE document_id = ?", doc)).isEqualTo(2);
    }

    @Test
    void aSnapshotIsCollectedAtTheDocumentsCollectionPoint() {
        UUID doc = document(ALICE);
        DocOps.Author a = new DocOps.Author(replicaId());
        OpId node = a.next();
        List<Change> changes = List.of(a.change("Create", DocOps.create(wellKnown(LAYERS), DocOps.path("Old", ""))),
                a.change("Delete", DocOps.delete(node)),
                a.change("Keep", DocOps.create(wellKnown(LAYERS), DocOps.path("Kept", ""))));
        push(ALICE, null, doc, changes.toArray(Change[]::new));
        long later = System.currentTimeMillis() + Engine.DELETED_NODE_RETENTION_MS + 60_000;
        exec("UPDATE document SET collect_seq = 2, collect_time_ms = ? WHERE id = ?", later, doc);

        run(() -> snapshotter.snapshot(doc));
        Engine expected = replay(changes);
        expected.collect(2, Clock.fixed(Instant.ofEpochMilli(later), ZoneOffset.UTC));
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ?", doc)).isEqualTo(StateHash.hex(expected.stateHash()));
        assertThat(value("SELECT collect_seq FROM snapshot WHERE document_id = ?", doc)).isEqualTo(2L);
        assertThat(replayHash(changes)).isNotEqualTo(StateHash.hex(expected.stateHash()));
    }

    @Test
    void theRunSnapshotsDueDocumentsAndSurvivesABrokenOne() {
        // Due by count: more changes since the newest snapshot than the threshold.
        UUID many = document(ALICE);
        long replica = replicaId();
        for (long s = 1; s <= 2001; s++) {
            row(many, s, replica, s, change(replica, s).toByteArray(), 0, 0);
        }
        // Due by age: created over 30 minutes ago with a change and no snapshot.
        UUID old = document(ALICE);
        push(ALICE, null, old, change(replicaId(), 1));
        exec("UPDATE document SET created_at = now() - interval '1 hour' WHERE id = ?", old);
        // Due by a closed subscription, but its log does not decode: logged, and the run goes on.
        UUID broken = document(ALICE);
        row(broken, 1, replicaId(), 1, new byte[] {(byte) 0xff, 1}, 0, 0);
        exec("UPDATE document SET snapshot_due_at = now() WHERE id = ?", broken);
        // Not due: a recent document with a few changes.
        UUID quiet = document(ALICE);
        push(ALICE, null, quiet, change(replicaId(), 1));

        run(() -> snapshotter.scheduled());
        assertThat(count("SELECT count(*) FROM snapshot WHERE document_id = ? AND server_seq = 2001", many)).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM snapshot WHERE document_id = ?", old)).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM snapshot WHERE document_id = ?", broken)).isZero();
        assertThat(value("SELECT snapshot_due_at FROM document WHERE id = ?", broken)).isNotNull();
        assertThat(count("SELECT count(*) FROM snapshot WHERE document_id = ?", quiet)).isZero();
    }

    @Test
    void aSnapshotThatDoesNotDecodeFailsTheBuild() {
        UUID doc = document(ALICE);
        push(ALICE, null, doc, change(replicaId(), 1), change(replicaId(), 1));
        String key = Snapshots.key(doc, 1);
        run(() -> store.put(key, com.villagecompute.wiretuner.crdt.Zstd.compress(new byte[] {1, 2, 3}), "application/zstd"));
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, uncompressed_size, node_count)"
                + " VALUES (?, 1, ?, ?, 1, 3, 0)", doc, key, "0".repeat(64));
        org.assertj.core.api.Assertions.assertThatThrownBy(() -> run(() -> snapshotter.snapshot(doc)))
                .hasMessageContaining("snapshot does not decode");
    }

    @Test
    void theLastSubscriptionClosingMarksTheDocumentDue() {
        UUID doc = document(ALICE);
        long replica = replicaId();
        Subscription first = subscribe(ALICE, null, doc, replica, 0);
        first.next(com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase.WELCOME);
        Subscription second = subscribe(ALICE, null, doc, replicaId(), 0);
        second.next(com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase.WELCOME);
        push(ALICE, null, doc, change(replica, 1));
        first.changes(1);
        second.changes(1);

        first.cancel();
        await(() -> first.done.isDone());
        sleep(500);
        assertThat(value("SELECT snapshot_due_at FROM document WHERE id = ?", doc)).isNull();
        second.cancel();
        await(() -> value("SELECT snapshot_due_at FROM document WHERE id = ?", doc) != null);

        // Nothing new since the newest snapshot: closing does not mark it again.
        run(() -> snapshotter.snapshot(doc));
        run(() -> snapshotter.closed(doc));
        assertThat(value("SELECT snapshot_due_at FROM document WHERE id = ?", doc)).isNull();
    }

    static void sleep(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            throw new IllegalStateException(e);
        }
    }
}
