package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.ListHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.ListHistoryResponse;
import com.villagecompute.wiretuner.docs.v1.NameVersionRequest;
import com.villagecompute.wiretuner.docs.v1.PinVersionRequest;
import com.villagecompute.wiretuner.docs.v1.VersionServiceGrpc;

import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * COLLAB-020's retention job: beyond the window (30 days, or a team's longer one) a document keeps only
 * its pinned versions' snapshots -- their changes are gone from the timeline and from cold storage,
 * the pinned state and the document's blobs are not -- held back by the stable point and by an active
 * branch's merge point.
 */
@QuarkusTest
class RetentionJobTest extends HistoryTestSupport {

    @GrpcClient("versions")
    VersionServiceGrpc.VersionServiceBlockingStub versions;

    @Inject
    RetentionJob retention;

    @Inject
    Snapshotter snapshotter;

    @Inject
    Compactor compactor;

    @Inject
    DocumentStates states;

    /** A document of {@code n} changes by Alice, each creating a named path; returns the changes. */
    List<Change> objects(UUID doc, int n) {
        DocOps.Author a = new DocOps.Author(replicaId());
        List<Change> changes = new ArrayList<>();
        for (int i = 0; i < n; i++) {
            changes.add(a.change("Object " + i, DocOps.create(wellKnown(LAYERS), DocOps.path("Object " + i, ""))));
        }
        push(ALICE, null, doc, changes.toArray(Change[]::new));
        return changes;
    }

    /** A version of {@code doc} at {@code seq}, pinned or not. */
    void version(UUID doc, long seq, boolean pinned) {
        VersionServiceGrpc.VersionServiceBlockingStub alices = TestUsers.as(versions, ALICE);
        String id = alices.nameVersion(NameVersionRequest.newBuilder().setDocumentId(doc.toString())
                .setVersionId(uuid7().toString()).setName("At " + seq).setServerSeq(seq).build()).getVersion().getId();
        alices.pinVersion(PinVersionRequest.newBuilder().setVersionId(id).setPinned(true).build());
        if (!pinned) {
            alices.pinVersion(PinVersionRequest.newBuilder().setVersionId(id).setPinned(false).build());
        }
    }

    void age(UUID doc, long seq, int days) {
        exec("UPDATE snapshot SET created_at = now() - make_interval(days => ?) WHERE document_id = ? AND server_seq = ?",
                days, doc, seq);
    }

    List<Object> snapshots(UUID doc) {
        return column("SELECT server_seq FROM snapshot WHERE document_id = ? ORDER BY server_seq", doc);
    }

    @Test
    void pastTheWindowOnlyPinnedVersionsRemainWithTheirBlobs() {
        UUID doc = document(ALICE);
        List<Change> changes = objects(doc, 8);
        run(() -> snapshotter.snapshot(doc));
        changes.addAll(objects(doc, 4));
        run(() -> snapshotter.snapshot(doc));
        // Rows 1-8 go cold (the newest four stay hot); versions at 3 (pinned) and 5 (pinned, then released).
        assertThat(run(() -> compactor.compact(doc))).isPositive();
        version(doc, 3, true);
        version(doc, 5, false);
        List<Object> segmentKeys = column("SELECT object_key FROM cold_segment WHERE document_id = ?", doc);
        String loose = Snapshots.key(doc, 5);
        byte[] bytes = {7, 7, 7};
        String blob = "ab".repeat(32);
        run(() -> store.put(BlobStore.key(blob), bytes, "image/png"));
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key) VALUES (?, 3, 'image/png', ?) ON CONFLICT DO NOTHING",
                blob, BlobStore.key(blob));
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?)", doc, blob);
        long names = count("SELECT count(*) FROM node_name WHERE document_id = ?", doc);

        // The snapshot at 8 is past the window, but a replica has acknowledged only 6: nothing goes.
        age(doc, 8, 31);
        exec("UPDATE document SET stable_seq = 6 WHERE id = ?", doc);
        run(() -> retention.scheduled());
        assertThat(snapshots(doc)).containsExactly(3L, 5L, 8L, 12L);
        assertThat(count("SELECT count(*) FROM cold_segment WHERE document_id = ?", doc)).isPositive();

        exec("UPDATE document SET stable_seq = 12 WHERE id = ?", doc);
        run(() -> retention.scheduled());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isEqualTo(4);
        assertThat(count("SELECT count(*) FROM cold_segment WHERE document_id = ?", doc)).isZero();
        assertThat(segmentKeys).isNotEmpty().allSatisfy(key -> assertThat(stored((String) key)).isFalse());
        assertThat(count("SELECT count(*) FROM change_node WHERE document_id = ? AND server_seq <= 8", doc)).isZero();
        assertThat(count("SELECT count(*) FROM change_node WHERE document_id = ? AND server_seq > 8", doc)).isPositive();
        assertThat(count("SELECT count(*) FROM node_name WHERE document_id = ?", doc)).isEqualTo(names);
        // The pinned version's snapshot and the cut's stay; the released one's goes, object and all.
        assertThat(snapshots(doc)).containsExactly(3L, 8L, 12L);
        assertThat(stored(loose)).isFalse();
        assertThat(StateHash.hex(run(() -> states.at(doc, 3)).stateHash())).isEqualTo(replayHash(changes.subList(0, 3)));
        assertThat(stored(BlobStore.key(blob))).isTrue();
        assertThat(count("SELECT count(*) FROM document_blob WHERE document_id = ?", doc)).isEqualTo(1);
        // The timeline starts after the cut.
        ListHistoryResponse history = TestUsers.as(versions, ALICE)
                .listHistory(ListHistoryRequest.newBuilder().setDocumentId(doc.toString()).build());
        assertThat(history.getRetainedFromSeq()).isEqualTo(9);
        assertThat(history.getRowsList()).filteredOn(row -> row.hasSession())
                .allSatisfy(row -> assertThat(row.getSession().getFirstServerSeq()).isGreaterThanOrEqualTo(9));

        // A second run finds nothing to do.
        run(() -> retention.run());
        assertThat(snapshots(doc)).containsExactly(3L, 8L, 12L);
    }

    @Test
    void aTeamsLongerWindowAndAnActiveBranchHoldHistoryBack() {
        UUID doc = document(ALICE);
        objects(doc, 3);
        run(() -> snapshotter.snapshot(doc));
        UUID team = team(alice, "editor");
        exec("UPDATE document SET owner_account_id = NULL, team_id = ?, stable_seq = 3 WHERE id = ?", team, doc);
        exec("UPDATE team SET history_retention_days = 60 WHERE id = ?", team);
        age(doc, 3, 31);
        run(() -> retention.run());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isEqualTo(3);
        age(doc, 3, 61);
        run(() -> retention.run());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", doc)).isZero();

        // A branch's changes since its fork (or last merge) are what a merge replays: they stay while it is active.
        UUID parent = document(ALICE);
        UUID branch = document(ALICE);
        exec("INSERT INTO branch (document_id, parent_document_id, fork_seq, name) VALUES (?, ?, 0, 'Side')", branch, parent);
        objects(branch, 2);
        run(() -> snapshotter.snapshot(branch));
        exec("UPDATE document SET stable_seq = 2 WHERE id = ?", branch);
        age(branch, 2, 31);
        run(() -> retention.run());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", branch)).isEqualTo(2);
        exec("UPDATE branch SET merged_branch_seq = 2 WHERE document_id = ?", branch);
        run(() -> retention.run());
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", branch)).isZero();
    }
}
