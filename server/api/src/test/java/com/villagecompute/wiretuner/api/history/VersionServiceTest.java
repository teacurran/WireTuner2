package com.villagecompute.wiretuner.api.history;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.docs.v1.ChangeSummary;
import com.villagecompute.wiretuner.docs.v1.CreateFolderRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteVersionRequest;
import com.villagecompute.wiretuner.docs.v1.Document;
import com.villagecompute.wiretuner.docs.v1.HistoryRow;
import com.villagecompute.wiretuner.docs.v1.ListHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.ListHistoryResponse;
import com.villagecompute.wiretuner.docs.v1.ListNodeHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.ListNodeHistoryResponse;
import com.villagecompute.wiretuner.docs.v1.ListVersionsRequest;
import com.villagecompute.wiretuner.docs.v1.ListVersionsResponse;
import com.villagecompute.wiretuner.docs.v1.NameVersionRequest;
import com.villagecompute.wiretuner.docs.v1.PinVersionRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreAsCopyRequest;
import com.villagecompute.wiretuner.docs.v1.Session;
import com.villagecompute.wiretuner.docs.v1.UpdateVersionRequest;
import com.villagecompute.wiretuner.docs.v1.Version;
import com.villagecompute.wiretuner.docs.v1.VersionServiceGrpc;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SRV-011: VersionService -- named versions as bookmarks, pinning, restore-as-copy, the timeline
 * and node history (the history scan is 40 rows in tests); COLLAB-020: node names at the time, register
 * attributes, the object-name query, node history from the index, and history across cold segments.
 */
@QuarkusTest
class VersionServiceTest extends HistoryTestSupport {

    @GrpcClient("versions")
    VersionServiceGrpc.VersionServiceBlockingStub versions;

    @jakarta.inject.Inject
    Snapshotter snapshotter;

    @jakarta.inject.Inject
    Compactor compactor;

    VersionServiceGrpc.VersionServiceBlockingStub as(String user) {
        return TestUsers.as(versions, user);
    }

    NameVersionRequest.Builder name(UUID document, String name) {
        return NameVersionRequest.newBuilder().setDocumentId(document.toString()).setVersionId(uuid7().toString()).setName(name);
    }

    /** Alice's document with three changes of hers; returns it. */
    record Doc(UUID id, DocOps.Author author, List<Change> changes) {
    }

    Doc doc() {
        UUID id = document(ALICE);
        share(id, bob, "editor");
        share(id, carol, "viewer");
        DocOps.Author a = new DocOps.Author(replicaId());
        List<Change> changes = List.of(a.change("One", DocOps.create(wellKnown(LAYERS), DocOps.path("One", ""))),
                a.change("Two", DocOps.create(wellKnown(LAYERS), DocOps.path("Two", ""))),
                a.change("Three", DocOps.noop(), DocOps.noop()));
        push(ALICE, null, id, changes.toArray(Change[]::new));
        return new Doc(id, a, changes);
    }

    @Test
    void namedVersionsAreBookmarksThatCanBeRenamedPinnedAndDeleted() {
        Doc doc = doc();
        NameVersionRequest atHead = name(doc.id(), "Sent to client").setNote("v1").build();
        Version version = as(BOB).nameVersion(atHead).getVersion();
        assertThat(version.getServerSeq()).isEqualTo(3);
        assertThat(version.getCreatedBy().getUserId()).isEqualTo(bob.toString());
        assertThat(version.getNote()).isEqualTo("v1");
        assertThat(version.getPinned()).isFalse();
        assertThat(as(BOB).nameVersion(atHead).getVersion().getId()).isEqualTo(version.getId());
        assertFails(() -> as(CAROL).nameVersion(name(doc.id(), "No").build()), Status.Code.PERMISSION_DENIED,
                "ROLE_INSUFFICIENT");
        UUID other = document(ALICE);
        assertFails(() -> as(ALICE).nameVersion(atHead.toBuilder().setDocumentId(other.toString()).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
        assertFails(() -> as(ALICE).nameVersion(name(doc.id(), "Future").setServerSeq(9).build()),
                Status.Code.FAILED_PRECONDITION, "HISTORY_UNAVAILABLE");

        // Named offline: the seq at which the named local change landed.
        Version offline = as(ALICE).nameVersion(name(doc.id(), "Offline")
                .setThroughLocalChange(DocOps.id(2, doc.author().replica)).setServerSeq(1).build()).getVersion();
        assertThat(offline.getServerSeq()).isEqualTo(2);
        assertFails(() -> as(ALICE).nameVersion(name(doc.id(), "Unknown")
                .setThroughLocalChange(DocOps.id(1, 12345)).build()), Status.Code.FAILED_PRECONDITION, "HISTORY_UNAVAILABLE");
        Version early = as(ALICE).nameVersion(name(doc.id(), "Early").setServerSeq(1).build()).getVersion();
        assertThat(early.getServerSeq()).isEqualTo(1);

        // Listing, newest first, a page at a time; any role reads.
        ListVersionsResponse page = as(CAROL).listVersions(ListVersionsRequest.newBuilder().setDocumentId(doc.id().toString())
                .setPageSize(2).build());
        assertThat(page.getVersionsList()).extracting(Version::getName).containsExactly("Early", "Offline");
        ListVersionsResponse rest = as(CAROL).listVersions(ListVersionsRequest.newBuilder().setDocumentId(doc.id().toString())
                .setCursor(page.getNextCursor()).build());
        assertThat(rest.getVersionsList()).extracting(Version::getName).containsExactly("Sent to client");
        assertThat(rest.getNextCursor()).isEmpty();

        // Renaming, re-noting, and who may.
        UUID id = UUID.fromString(version.getId());
        Version renamed = as(BOB).updateVersion(UpdateVersionRequest.newBuilder().setVersionId(id.toString()).setName("Approved")
                .build()).getVersion();
        assertThat(renamed.getName()).isEqualTo("Approved");
        assertThat(renamed.getNote()).isEqualTo("v1");
        Version noted = as(BOB).updateVersion(UpdateVersionRequest.newBuilder().setVersionId(id.toString()).setNote("v2")
                .build()).getVersion();
        assertThat(noted.getName()).isEqualTo("Approved");
        assertThat(noted.getNote()).isEqualTo("v2");
        assertFails(() -> as(CAROL).updateVersion(UpdateVersionRequest.newBuilder().setVersionId(id.toString()).setName("x")
                .build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        // Pinning materializes the state at exactly the version's seq.
        Version pinned = as(ALICE).pinVersion(PinVersionRequest.newBuilder().setVersionId(offline.getId()).setPinned(true)
                .build()).getVersion();
        assertThat(pinned.getPinned()).isTrue();
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = 2", doc.id()))
                .isEqualTo(replayHash(doc.changes().subList(0, 2)));
        assertThat(as(ALICE).pinVersion(PinVersionRequest.newBuilder().setVersionId(offline.getId()).build())
                .getVersion().getPinned()).isFalse();
        Version empty = as(ALICE).nameVersion(name(doc(ALICE), "Empty").build()).getVersion();
        assertThat(empty.getServerSeq()).isZero();
        assertThat(as(ALICE).pinVersion(PinVersionRequest.newBuilder().setVersionId(empty.getId()).setPinned(true).build())
                .getVersion().getPinned()).isTrue();

        as(ALICE).deleteVersion(DeleteVersionRequest.newBuilder().setVersionId(id.toString()).build());
        assertFails(() -> as(ALICE).deleteVersion(DeleteVersionRequest.newBuilder().setVersionId(id.toString()).build()),
                Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");
    }

    UUID doc(String user) {
        return document(user);
    }

    @Test
    void restoreAsCopyMakesANewDocumentFromTheStateAtASeq() {
        Doc doc = doc();
        Document copy = as(CAROL).restoreAsCopy(RestoreAsCopyRequest.newBuilder().setDocumentId(doc.id().toString())
                .setServerSeq(2).setNewDocumentId(uuid7().toString()).build()).getDocument();
        assertThat(copy.getSpaceId()).isEqualTo(carol.toString());
        assertThat(copy.getName()).isEqualTo("Sync");
        assertThat(copy.getHeadSeq()).isEqualTo(2);
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ?", UUID.fromString(copy.getId())))
                .isEqualTo(replayHash(doc.changes().subList(0, 2)));

        UUID folder = UUID.fromString(TestUsers.as(docs, ALICE).createFolder(CreateFolderRequest.newBuilder()
                .setSpaceId(alice.toString()).setName("Restored").build()).getFolder().getId());
        Document named = as(ALICE).restoreAsCopy(RestoreAsCopyRequest.newBuilder().setDocumentId(doc.id().toString())
                .setServerSeq(1).setNewDocumentId(uuid7().toString()).setName("Back then").setSpaceId(alice.toString())
                .setFolderId(folder.toString()).build()).getDocument();
        assertThat(named.getName()).isEqualTo("Back then");
        assertThat(named.getFolderId()).isEqualTo(folder.toString());
    }

    List<String> rows(ListHistoryResponse response) {
        List<String> rows = new ArrayList<>();
        for (HistoryRow row : response.getRowsList()) {
            rows.add(row.hasVersion() ? "v:" + row.getVersion().getName()
                    : "s:" + row.getSession().getFirstServerSeq() + "-" + row.getSession().getLastServerSeq());
        }
        return rows;
    }

    ListHistoryResponse history(ListHistoryRequest.Builder request) {
        return as(CAROL).listHistory(request.build());
    }

    @Test
    void theTimelineGroupsSessionsAndInterleavesVersions() {
        Doc doc = doc();
        long bobReplica = replicaId();
        push(BOB, null, doc.id(), change(bobReplica, 1, "Bob one"), change(bobReplica, 2, "Bob two"));
        DocOps.Author a = doc.author();
        List<Change> more = new ArrayList<>();
        for (int i = 0; i < 6; i++) {
            more.add(a.change("Alice " + i, DocOps.noop()));
        }
        push(ALICE, null, doc.id(), more.toArray(Change[]::new));
        // Alice's first three changes were an hour earlier: a session of their own despite the same author.
        exec("UPDATE change_log SET wall_time = now() - interval '1 hour' WHERE document_id = ? AND server_seq <= 3", doc.id());
        as(ALICE).nameVersion(name(doc.id(), "After Bob").setServerSeq(5).build());
        as(ALICE).nameVersion(name(doc.id(), "Start").setServerSeq(1).build());
        String id = doc.id().toString();

        ListHistoryResponse all = history(ListHistoryRequest.newBuilder().setDocumentId(id));
        assertThat(rows(all)).containsExactly("s:6-11", "v:After Bob", "s:4-5", "s:1-3", "v:Start");
        assertThat(all.getRetainedFromSeq()).isEqualTo(1);
        assertThat(all.getNextCursor()).isEmpty();
        Session big = all.getRows(0).getSession();
        assertThat(big.getChangeCount()).isEqualTo(6);
        assertThat(big.getChangesList()).isEmpty();
        assertThat(big.getAuthor().getUserId()).isEqualTo(alice.toString());
        Session bobs = all.getRows(2).getSession();
        assertThat(bobs.getChangesList()).extracting(ChangeSummary::getLabel).containsExactly("Bob two", "Bob one");
        assertThat(all.getRows(3).getSession().getNodeCount()).isEqualTo(2);

        // Expanding the big session, filtering by author or label, paging.
        assertThat(history(ListHistoryRequest.newBuilder().setDocumentId(id).setExpandSession(6)).getRows(0).getSession()
                .getChangesCount()).isEqualTo(6);
        assertThat(rows(history(ListHistoryRequest.newBuilder().setDocumentId(id).setQuery("bob")))).contains("s:4-5")
                .doesNotContain("s:6-11");
        ListHistoryResponse first = history(ListHistoryRequest.newBuilder().setDocumentId(id).setPageSize(1));
        assertThat(rows(first)).containsExactly("s:6-11");
        ListHistoryResponse second = history(ListHistoryRequest.newBuilder().setDocumentId(id).setPageSize(1)
                .setCursor(first.getNextCursor()));
        assertThat(rows(second)).containsExactly("v:After Bob", "s:4-5");
        assertThat(rows(history(ListHistoryRequest.newBuilder().setDocumentId(id).setBeforeServerSeq(4))))
                .containsExactly("s:1-3", "v:Start");
        assertFails(() -> history(ListHistoryRequest.newBuilder().setDocumentId(id).setCursor(Cursors.encode("x"))),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    @Test
    void aLongLogIsReadAScanAtATimeAndMergedChangesNameTheirBranch() {
        UUID id = document(ALICE);
        share(id, carol, "viewer");
        long replica = replicaId();
        List<Change> changes = new ArrayList<>();
        for (long s = 1; s <= 45; s++) {
            // A cold change's time is its own: the client's clock.
            changes.add(change(replica, s, "Edit " + s).toBuilder().setWallTimeMs(System.currentTimeMillis()).build());
        }
        pushAll(ALICE, null, id, changes);
        // All but the newest four rows go cold: the timeline reads through the segments.
        run(() -> snapshotter.snapshot(id));
        assertThat(run(() -> compactor.compact(id))).isPositive();
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", id)).isEqualTo(4);
        // The first page reads 40 rows: the session is cut there and continues on the next page.
        ListHistoryResponse first = history(ListHistoryRequest.newBuilder().setDocumentId(id.toString()));
        assertThat(rows(first)).containsExactly("s:6-45");
        ListHistoryResponse rest = history(ListHistoryRequest.newBuilder().setDocumentId(id.toString())
                .setCursor(first.getNextCursor()));
        assertThat(rows(rest)).containsExactly("s:1-5");
        // Nothing in a full scan matches: no rows and no cursor.
        ListHistoryResponse none = history(ListHistoryRequest.newBuilder().setDocumentId(id.toString()).setQuery("zzz"));
        assertThat(none.getRowsList()).isEmpty();
        assertThat(none.getNextCursor()).isEmpty();

        UUID branch = document(ALICE);
        exec("INSERT INTO branch (document_id, parent_document_id, fork_seq, name) VALUES (?, ?, 0, 'Side')", branch, id);
        exec("UPDATE change_log SET merged_from_branch_id = ? WHERE document_id = ? AND server_seq = 45", branch, id);
        Session merged = history(ListHistoryRequest.newBuilder().setDocumentId(id.toString()).setPageSize(1)).getRows(0)
                .getSession();
        assertThat(merged.getMergedFromBranchId()).isEqualTo(branch.toString());
        assertThat(merged.getMergedFromBranchName()).isEqualTo("Side");
        assertThat(merged.getFirstServerSeq()).isEqualTo(45);
    }

    @Test
    void nodeHistoryListsTheChangesThatNamedANode() {
        UUID id = document(ALICE);
        share(id, carol, "viewer");
        DocOps.Author a = new DocOps.Author(replicaId());
        OpId node = a.next();
        List<Change> changes = new ArrayList<>();
        changes.add(a.change("Create", DocOps.create(wellKnown(LAYERS), DocOps.path("Tracked", ""))));
        for (int i = 1; i < 40; i++) {
            changes.add(i % 10 == 0 ? a.change("Rename " + i, DocOps.rename(node, "Tracked " + i)) : a.change("Other " + i,
                    DocOps.noop()));
        }
        pushAll(ALICE, null, id, changes);
        // A full scan of hot rows: the page is cut there, with a cursor.
        ListHistoryResponse scanned = history(ListHistoryRequest.newBuilder().setDocumentId(id.toString()));
        assertThat(rows(scanned)).containsExactly("s:1-40");
        ListNodeHistoryRequest.Builder request = ListNodeHistoryRequest.newBuilder().setDocumentId(id.toString()).setNode(node)
                .setPageSize(2);
        ListNodeHistoryResponse first = as(CAROL).listNodeHistory(request.build());
        assertThat(first.getChangesList()).extracting(ChangeSummary::getLabel).containsExactly("Rename 30", "Rename 20");
        assertThat(first.getAuthorsList()).allMatch(p -> p.getUserId().equals(alice.toString()));
        assertThat(first.getChanges(0).getNodes(0).getId()).isEqualTo(node);
        ListNodeHistoryResponse rest = as(CAROL).listNodeHistory(request.setPageSize(0).setCursor(first.getNextCursor())
                .build());
        assertThat(rest.getChangesList()).extracting(ChangeSummary::getLabel).containsExactly("Rename 10", "Create");
        assertThat(rest.getNextCursor()).isEmpty();
    }

    @Test
    void rowsNameTheirNodesAsTheyWereAndTheRegistersWrittenHotAndCold() {
        UUID id = document(ALICE);
        share(id, carol, "viewer");
        DocOps.Author a = new DocOps.Author(replicaId());
        OpId logo = a.next();
        List<Change> changes = new ArrayList<>();
        changes.add(a.change("Create", DocOps.create(wellKnown(LAYERS), DocOps.path("Logo", ""))));
        changes.add(a.change("Plain", DocOps.create(wellKnown(LAYERS), DocOps.path("", ""))));
        changes.add(a.change("Rename", DocOps.rename(logo, "Badge")));
        for (int i = 0; i < 9; i++) {
            changes.add(a.change("Edit " + i, DocOps.noop()));
        }
        changes.add(a.change("Touch", DocOps.clearNote(logo)));
        push(ALICE, null, id, changes.toArray(Change[]::new));
        String doc = id.toString();

        for (int pass = 0; pass < 2; pass++) {
            Session all = history(ListHistoryRequest.newBuilder().setDocumentId(doc).setExpandSession(1)).getRows(0)
                    .getSession();
            List<ChangeSummary> rows = all.getChangesList();
            assertThat(rows).hasSize(13);
            assertThat(rows.get(12).getLabel()).isEqualTo("Create");
            assertThat(rows.get(12).getNodes(0).getName()).isEqualTo("Logo");
            assertThat(rows.get(12).getAttributesList()).isEmpty();
            assertThat(rows.get(11).getNodes(0).getName()).isEqualTo("Path");
            assertThat(rows.get(10).getNodes(0).getName()).isEqualTo("Badge");
            assertThat(rows.get(10).getAttributesList()).containsExactly("Name");
            assertThat(rows.get(0).getNodes(0).getName()).isEqualTo("Badge");
            assertThat(rows.get(0).getAttributesList()).containsExactly("Note");
            // An object's name, then or now, finds the changes that touched it.
            Session named = history(ListHistoryRequest.newBuilder().setDocumentId(doc).setQuery("logo")).getRows(0)
                    .getSession();
            assertThat(named.getChangesList()).extracting(ChangeSummary::getLabel).containsExactly("Touch", "Rename", "Create");
            // Node history from the index, a page at a time.
            ListNodeHistoryRequest.Builder request = ListNodeHistoryRequest.newBuilder().setDocumentId(doc).setNode(logo)
                    .setPageSize(2);
            ListNodeHistoryResponse first = as(CAROL).listNodeHistory(request.build());
            assertThat(first.getChangesList()).extracting(ChangeSummary::getLabel).containsExactly("Touch", "Rename");
            ListNodeHistoryResponse rest = as(CAROL).listNodeHistory(request.setCursor(first.getNextCursor()).build());
            assertThat(rest.getChangesList()).extracting(ChangeSummary::getLabel).containsExactly("Create");
            assertThat(rest.getAuthorsList()).singleElement().satisfies(p -> assertThat(p.getUserId()).isEqualTo(alice.toString()));
            // Then everything but the newest four rows goes cold, and the same answers come from the segments.
            run(() -> snapshotter.snapshot(id));
            run(() -> compactor.compact(id));
        }
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", id)).isEqualTo(4);
        ListHistoryResponse older = history(ListHistoryRequest.newBuilder().setDocumentId(doc).setBeforeServerSeq(4));
        assertThat(rows(older)).containsExactly("s:1-3");
        assertThat(older.getRetainedFromSeq()).isEqualTo(1);
    }

    @Test
    void aColdChangeOfAnUnboundReplicaHasNoAuthorInTheTimeline() {
        UUID id = document(ALICE);
        share(id, carol, "viewer");
        long replica = replicaId();
        for (long s = 1; s <= 6; s++) {
            row(id, s, replica, s, change(replica, s, "Raw " + s).toBuilder().setWallTimeMs(System.currentTimeMillis()).build()
                    .toByteArray(), 0, 0);
        }
        exec("INSERT INTO snapshot (document_id, server_seq, object_key, state_hash, size_bytes, node_count)"
                + " VALUES (?, 6, 'unused', ?, 0, 0)", id, "0".repeat(64));
        run(() -> compactor.compact(id));
        Session raw = history(ListHistoryRequest.newBuilder().setDocumentId(id.toString())).getRows(0).getSession();
        assertThat(raw.getChangeCount()).isEqualTo(6);
        assertThat(raw.getAuthor().getUserId()).isEmpty();
    }
}
