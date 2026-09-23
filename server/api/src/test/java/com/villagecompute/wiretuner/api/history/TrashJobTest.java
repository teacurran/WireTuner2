package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/** SRV-013: documents trashed 30 days ago go for good with their branches and objects; orphaned blobs go. */
@QuarkusTest
class TrashJobTest extends HistoryTestSupport {

    @Inject
    TrashJob trash;

    /** A blob row (with its object) created {@code daysAgo} days ago; returns its sha256. */
    String blob(int daysAgo) {
        String sha = UUID.randomUUID().toString().replace("-", "") + UUID.randomUUID().toString().replace("-", "");
        String key = "blobs/" + sha.substring(0, 2) + "/" + sha;
        run(() -> store.put(key, new byte[] {1, 2, 3}, "application/octet-stream"));
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key, created_at)"
                + " VALUES (?, 3, 'application/octet-stream', ?, now() - make_interval(days => ?))", sha, key, daysAgo);
        return sha;
    }

    String key(String sha) {
        return "blobs/" + sha.substring(0, 2) + "/" + sha;
    }

    @Test
    void expiredDocumentsGoWithTheirBranchesObjectsAndOrphanedBlobs() {
        UUID expired = document(ALICE);
        UUID branch = document(ALICE);
        UUID recent = document(ALICE);
        exec("INSERT INTO branch (document_id, parent_document_id, fork_seq) VALUES (?, ?, 0)", branch, expired);
        exec("UPDATE document SET trashed_at = now() - interval '31 days' WHERE id = ?", expired);
        exec("UPDATE document SET trashed_at = now() - interval '1 day' WHERE id = ?", recent);
        String snapshotKey = Snapshots.key(expired, 1);
        String segmentKey = "cold/" + expired + "/1-1";
        run(() -> store.put(snapshotKey, new byte[] {1}, "application/zstd"));
        run(() -> store.put(segmentKey, new byte[] {1}, "application/zstd"));
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 1, ?, ?, 1, 0)", expired, snapshotKey, "0".repeat(64));
        exec("INSERT INTO cold_segment (document_id, from_seq, to_seq, object_key, compressed_size) VALUES (?, 1, 1, ?, 1)",
                expired, segmentKey);

        String orphan = blob(2);
        String young = blob(0);
        String referenced = blob(2);
        String thumbnail = blob(2);
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?)", recent, referenced);
        exec("UPDATE document SET thumbnail_blob = ? WHERE id = ?", thumbnail, recent);
        // Referenced only by the expired document: an orphan once it is gone.
        String released = blob(2);
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?)", expired, released);

        run(() -> trash.scheduled());
        assertThat(count("SELECT count(*) FROM document WHERE id IN (?, ?)", expired, branch)).isZero();
        assertThat(count("SELECT count(*) FROM document WHERE id = ?", recent)).isEqualTo(1);
        assertThat(stored(snapshotKey)).isFalse();
        assertThat(stored(segmentKey)).isFalse();
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 IN (?, ?)", orphan, released)).isZero();
        assertThat(stored(key(orphan))).isFalse();
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 IN (?, ?, ?)", young, referenced, thumbnail)).isEqualTo(3);
        assertThat(stored(key(referenced))).isTrue();
    }
}
