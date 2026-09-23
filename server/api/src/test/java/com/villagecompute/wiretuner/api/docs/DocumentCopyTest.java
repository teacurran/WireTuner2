package com.villagecompute.wiretuner.api.docs;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.CreateFolderRequest;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.Document;
import com.villagecompute.wiretuner.docs.v1.DocumentKind;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.DuplicateRequest;
import com.villagecompute.wiretuner.docs.v1.ForkRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SRV-009, SRV-007: Fork and Duplicate. A copy starts from the source's state at the fork point,
 * stored as the copy's snapshot there, then the caller's extra changes.
 */
@QuarkusTest
class DocumentCopyTest extends ServiceTestSupport {

    static final String HASH = "c".repeat(64);

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    UUID alice;
    UUID bob;
    UUID carol;

    @BeforeEach
    void accounts() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        carol = TestUsers.accountId(account, CAROL);
        TestUsers.accountId(account, DAVE);
    }

    /** A document of alice's with three changes: two from her replica (bound to her device), one from bob's. */
    record Source(UUID id, long aliceReplica, long bobReplica, UUID aliceDevice) {
    }

    Source source(String name) {
        UUID id = uuid7();
        long aliceReplica = replicaId();
        long bobReplica = replicaId();
        UUID device = UUID.randomUUID();
        as(docs, ALICE, device).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(alice.toString())
                .setName(name).setKind(DocumentKind.DOCUMENT_KIND_ILLUSTRATION_SINGLE_PAGE)
                .setInitialChange(change(aliceReplica, 1, "Create")).build());
        appendRow(id, 2, bobReplica, 1, change(bobReplica, 1, "Bob's"));
        exec("INSERT INTO replica (document_id, replica_id, account_id, device_id, last_seq) VALUES (?, ?, ?, ?, 1)",
                id, bobReplica, bob, UUID.randomUUID());
        appendRow(id, 3, aliceReplica, 2, change(aliceReplica, 2, "Alice's second"));
        exec("UPDATE document SET head_seq = 3, feature_level = 4 WHERE id = ?", id);
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key) VALUES (?, 1, 'image/png', 'k')"
                + " ON CONFLICT DO NOTHING", HASH);
        exec("INSERT INTO document_blob (document_id, sha256) VALUES (?, ?)", id, HASH);
        exec("UPDATE document SET thumbnail_blob = ?, thumbnail_at = now() WHERE id = ?", HASH, id);
        return new Source(id, aliceReplica, bobReplica, device);
    }

    void appendRow(UUID document, long serverSeq, long replica, long seq, Change change) {
        byte[] bytes = change.toByteArray();
        exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size) VALUES (?, ?, ?, ?, ?, ?)",
                document, serverSeq, replica, seq, bytes, bytes.length);
    }

    ForkRequest.Builder fork(Source source) {
        return ForkRequest.newBuilder().setSourceDocumentId(source.id().toString()).setNewDocumentId(uuid7().toString());
    }

    // ------------------------------------------------------------------------------------ Fork

    @Test
    void forkAtHeadCopiesTheLogBlobsAndThumbnailIntoTheCallersSpace() {
        Source source = source("Original");
        share(source.id(), carol, "viewer");
        Document copy = as(docs, CAROL).fork(fork(source).build()).getDocument();
        UUID copyId = UUID.fromString(copy.getId());

        assertThat(copy.getSpaceId()).isEqualTo(carol.toString());
        assertThat(copy.getOwnerAccountId()).isEqualTo(carol.toString());
        assertThat(copy.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
        assertThat(copy.getName()).isEqualTo("Original");
        assertThat(copy.getKind()).isEqualTo(DocumentKind.DOCUMENT_KIND_ILLUSTRATION_SINGLE_PAGE);
        assertThat(copy.getHeadSeq()).isEqualTo(3);
        assertThat(copy.getFeatureLevel()).isEqualTo(4);
        assertThat(copy.getThumbnailBlob().size()).isEqualTo(32);
        assertThat(copy.hasThumbnailAt()).isTrue();
        assertThat(copy.getIsTemplate()).isFalse();
        // No log rows below the fork point: the copy's snapshot there holds the source's state.
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ?", copyId)).isZero();
        Engine expected = new Engine();
        expected.apply(change(source.aliceReplica(), 1, "Create"), 1L);
        expected.apply(change(source.bobReplica(), 1, "Bob's"), 2L);
        expected.apply(change(source.aliceReplica(), 2, "Alice's second"), 3L);
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = 3", copyId))
                .isEqualTo(StateHash.hex(expected.stateHash()));
        assertThat(count("SELECT count(*) FROM document_blob WHERE document_id = ?", copyId)).isEqualTo(1);
        // Carol has no replica on the source, so none is bound on the copy.
        assertThat(count("SELECT count(*) FROM replica WHERE document_id = ?", copyId)).isZero();
    }

    @Test
    void forkAtAnEarlierSeqWithTheCallersUnsentChanges() {
        Source source = source("Diverged");
        Change mine = change(source.aliceReplica(), 2, "Alice's second");
        Change unsent = change(source.aliceReplica(), 3, "Alice's unsent");
        Change fresh = change(replicaId(), 1, "From a fresh replica");
        UUID folder = UUID.fromString(as(docs, ALICE).createFolder(CreateFolderRequest.newBuilder()
                .setSpaceId(alice.toString()).setName("Copies").build()).getFolder().getId());

        // At seq 2 alice's second change is not in the copied range, so it is appended along with the rest.
        Document copy = as(docs, ALICE).fork(fork(source).setAtServerSeq(2).addChanges(mine).addChanges(unsent)
                .addChanges(fresh).setName("My version").setSpaceId(alice.toString()).setFolderId(folder.toString())
                .build()).getDocument();
        UUID copyId = UUID.fromString(copy.getId());
        assertThat(copy.getName()).isEqualTo("My version");
        assertThat(copy.getFolderId()).isEqualTo(folder.toString());
        assertThat(copy.getHeadSeq()).isEqualTo(5);
        assertThat(column("SELECT seq FROM change_log WHERE document_id = ? AND replica_id = ? ORDER BY server_seq",
                copyId, source.aliceReplica())).containsExactly(2L, 3L);
        assertThat(column("SELECT server_seq FROM snapshot WHERE document_id = ?", copyId)).containsExactly(2L);
        // Alice's replica continues on the copy from her device; the fresh one is bound to the call's (none).
        assertThat(value("SELECT last_seq FROM replica WHERE document_id = ? AND replica_id = ?", copyId,
                source.aliceReplica())).isEqualTo(3L);
        assertThat(value("SELECT device_id FROM replica WHERE document_id = ? AND replica_id = ?", copyId,
                source.aliceReplica())).isEqualTo(source.aliceDevice());
        assertThat(value("SELECT device_id FROM replica WHERE document_id = ? AND replica_id = ?", copyId,
                fresh.getReplica())).isEqualTo(new UUID(0, 0));
        assertThat(count("SELECT count(*) FROM replica WHERE document_id = ? AND replica_id = ?", copyId,
                source.bobReplica())).isZero();
    }

    @Test
    void anExtraChangeAlreadyInTheRangeIsDroppedOrAConflict() {
        Source source = source("Replayed");
        Change accepted = change(source.aliceReplica(), 2, "Alice's second");
        UUID device = UUID.randomUUID();
        Document copy = as(docs, ALICE, device).fork(fork(source).addChanges(accepted).build()).getDocument();
        assertThat(copy.getHeadSeq()).isEqualTo(3);

        Change rewritten = change(source.aliceReplica(), 2, "Something else");
        assertFails(() -> as(docs, ALICE).fork(fork(source).addChanges(rewritten).build()),
                Status.Code.FAILED_PRECONDITION, "REPLICA_CONFLICT");
        Change foreign = change(source.bobReplica(), 2, "Not mine");
        assertFails(() -> as(docs, ALICE).fork(fork(source).addChanges(foreign).build()),
                Status.Code.FAILED_PRECONDITION, "REPLICA_CONFLICT");
        Change gap = change(source.aliceReplica(), 5, "Skipped ahead");
        assertFails(() -> as(docs, ALICE).fork(fork(source).addChanges(gap).build()), Status.Code.ABORTED, "SEQ_GAP");
    }

    @Test
    void forkNeedsRetainedHistoryAndCreateRights() {
        Source source = source("History");
        assertFails(() -> as(docs, ALICE).fork(fork(source).setAtServerSeq(9).build()),
                Status.Code.FAILED_PRECONDITION, "HISTORY_UNAVAILABLE");
        assertFails(() -> as(docs, DAVE).fork(fork(source).build()), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");
        assertFails(() -> as(docs, ALICE).fork(fork(source).setSpaceId(bob.toString()).build()),
                Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");

        exec("DELETE FROM change_log WHERE document_id = ? AND server_seq = 1", source.id());
        assertFails(() -> as(docs, ALICE).fork(fork(source).build()),
                Status.Code.FAILED_PRECONDITION, "HISTORY_UNAVAILABLE");
    }

    @Test
    void forkIsIdempotentByTheNewId() {
        Source source = source("Twice");
        ForkRequest request = fork(source).build();
        Document first = as(docs, ALICE).fork(request).getDocument();
        assertThat(as(docs, ALICE).fork(request).getDocument().getId()).isEqualTo(first.getId());
        UUID team = team(alice, "editor");
        assertFails(() -> as(docs, ALICE).fork(request.toBuilder().setSpaceId(team.toString()).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
    }

    @Test
    void forkIntoATeamMakesTheCallerTheOwnerRow() {
        Source source = source("To the team");
        UUID team = team(bob, "viewer");
        teamMember(team, alice, "member");
        Document copy = as(docs, ALICE).fork(fork(source).setSpaceId(team.toString()).build()).getDocument();
        assertThat(copy.getSpaceId()).isEqualTo(team.toString());
        assertThat(copy.getOwnerAccountId()).isEqualTo(alice.toString());
        assertThat(copy.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
    }

    @Test
    void aReplicaBoundToTheCallerButPastTheForkPointIsNotCarried() {
        Source source = source("Early");
        share(source.id(), bob, "viewer");
        Document copy = as(docs, BOB).fork(fork(source).setAtServerSeq(1).build()).getDocument();
        assertThat(copy.getHeadSeq()).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM replica WHERE document_id = ?", UUID.fromString(copy.getId()))).isZero();
    }

    @Test
    void aRetriedTeamCreateAnswersTheExistingDocument() {
        UUID team = team(alice, "editor");
        CreateRequest request = CreateRequest.newBuilder().setDocumentId(uuid7().toString())
                .setSpaceId(team.toString()).setName("Team retry").build();
        Document first = as(docs, ALICE).create(request).getDocument();
        assertThat(as(docs, ALICE).create(request).getDocument().getId()).isEqualTo(first.getId());
    }

    // ------------------------------------------------------------------------------- Duplicate

    @Test
    void duplicateCopiesAtHeadIntoTheSourcesFolder() {
        UUID folder = UUID.fromString(as(docs, ALICE).createFolder(CreateFolderRequest.newBuilder()
                .setSpaceId(alice.toString()).setName("Work").build()).getFolder().getId());
        UUID id = uuid7();
        as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(alice.toString())
                .setFolderId(folder.toString()).setName("Brochure").build());

        Document copy = as(docs, ALICE).duplicate(DuplicateRequest.newBuilder().setDocumentId(id.toString())
                .setNewDocumentId(uuid7().toString()).build()).getDocument();
        assertThat(copy.getName()).isEqualTo("Brochure copy");
        assertThat(copy.getFolderId()).isEqualTo(folder.toString());
        assertThat(copy.getSpaceId()).isEqualTo(alice.toString());
        assertThat(copy.getIsTemplate()).isFalse();
        assertThat(copy.hasThumbnailAt()).isFalse();

        Document template = as(docs, ALICE).duplicate(DuplicateRequest.newBuilder().setDocumentId(id.toString())
                .setNewDocumentId(uuid7().toString()).setName("Brochure template").setAsTemplate(true)
                .setFolderId(folder.toString()).build()).getDocument();
        assertThat(template.getName()).isEqualTo("Brochure template");
        assertThat(template.getIsTemplate()).isTrue();
    }

    @Test
    void duplicateIntoAnotherSpaceLandsAtItsRoot() {
        Source source = source("Shared source");
        share(source.id(), bob, "viewer");
        Document copy = as(docs, BOB).duplicate(DuplicateRequest.newBuilder().setDocumentId(source.id().toString())
                .setNewDocumentId(uuid7().toString()).setSpaceId(bob.toString()).build()).getDocument();
        assertThat(copy.getSpaceId()).isEqualTo(bob.toString());
        assertThat(copy.getFolderId()).isEmpty();
        assertThat(copy.getOwnerAccountId()).isEqualTo(bob.toString());
        assertThat(copy.getHeadSeq()).isEqualTo(3);
        // Bob's replica on the source continues on his copy.
        assertThat(count("SELECT count(*) FROM replica WHERE document_id = ? AND replica_id = ?",
                UUID.fromString(copy.getId()), source.bobReplica())).isEqualTo(1);

        // A viewer cannot duplicate into the source's (alice's) space.
        assertFails(() -> as(docs, BOB).duplicate(DuplicateRequest.newBuilder().setDocumentId(source.id().toString())
                .setNewDocumentId(uuid7().toString()).build()), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
    }
}
