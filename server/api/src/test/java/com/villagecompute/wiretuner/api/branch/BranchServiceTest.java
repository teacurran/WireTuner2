package com.villagecompute.wiretuner.api.branch;

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
import com.villagecompute.wiretuner.api.history.DocOps;
import com.villagecompute.wiretuner.api.history.HistoryTestSupport;
import com.villagecompute.wiretuner.api.history.Snapshotter;
import com.villagecompute.wiretuner.crdt.Engine;
import com.villagecompute.wiretuner.crdt.RegisterPath;
import com.villagecompute.wiretuner.crdt.StateHash;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.CommonProps;
import com.villagecompute.wiretuner.doc.v1.NodeProps;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.docs.v1.Branch;
import com.villagecompute.wiretuner.docs.v1.BranchServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.BranchState;
import com.villagecompute.wiretuner.docs.v1.CreateBranchRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteBranchRequest;
import com.villagecompute.wiretuner.docs.v1.GetBranchRequest;
import com.villagecompute.wiretuner.docs.v1.ListBranchesRequest;
import com.villagecompute.wiretuner.docs.v1.ListBranchesResponse;
import com.villagecompute.wiretuner.docs.v1.MergeBranchRequest;
import com.villagecompute.wiretuner.docs.v1.MergeBranchResponse;
import com.villagecompute.wiretuner.docs.v1.RenameBranchRequest;
import com.villagecompute.wiretuner.docs.v1.SetBranchStateRequest;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/** SRV-011: BranchService -- fork at head, list, rename, archive, trash, and merge by replay. */
@QuarkusTest
class BranchServiceTest extends HistoryTestSupport {

    @GrpcClient("branches")
    BranchServiceGrpc.BranchServiceBlockingStub branches;

    @Inject
    Snapshotter snapshotter;

    BranchServiceGrpc.BranchServiceBlockingStub as(String user) {
        return TestUsers.as(branches, user);
    }

    CreateBranchRequest.Builder create(UUID parent, String name) {
        return CreateBranchRequest.newBuilder().setParentDocumentId(parent.toString()).setBranchDocumentId(uuid7().toString())
                .setName(name);
    }

    /** The log of a document as stored, oldest first. */
    List<Change> log(String user, UUID document) {
        List<Change> changes = new ArrayList<>();
        blocking(user, null).fetchChanges(FetchChangesRequest.newBuilder().setDocumentId(document.toString()).build())
                .forEachRemaining(page -> page.getChangesList().forEach(c -> changes.add(c.getChange())));
        return changes;
    }

    static String name(Engine engine, OpId node) {
        byte[] value = engine.register(com.villagecompute.wiretuner.crdt.OpId.of(node),
                RegisterPath.of(NodeProps.PATH_FIELD_NUMBER, 1, CommonProps.NAME_FIELD_NUMBER)).value();
        try {
            return CommonProps.parseFrom(value).getName();
        } catch (com.google.protobuf.InvalidProtocolBufferException e) {
            throw new IllegalStateException(e);
        }
    }

    @Test
    void aBranchForksTheParentAndIsListedRenamedArchivedAndTrashed() {
        UUID parent = document(ALICE);
        share(parent, bob, "editor");
        share(parent, carol, "viewer");
        DocOps.Author a = new DocOps.Author(replicaId());
        List<Change> changes = List.of(a.change("One", DocOps.create(wellKnown(LAYERS), DocOps.path("One", ""))),
                a.change("Two", DocOps.create(wellKnown(LAYERS), DocOps.path("Two", ""))));
        push(ALICE, null, parent, changes.toArray(Change[]::new));

        assertFails(() -> as(CAROL).createBranch(create(parent, "Nope").build()), Status.Code.PERMISSION_DENIED,
                "ROLE_INSUFFICIENT");
        CreateBranchRequest request = create(parent, "Autumn palette").build();
        Branch branch = as(BOB).createBranch(request).getBranch();
        UUID branchId = UUID.fromString(branch.getBranchDocumentId());
        assertThat(branch.getParentDocumentId()).isEqualTo(parent.toString());
        assertThat(branch.getName()).isEqualTo("Autumn palette");
        assertThat(branch.getForkServerSeq()).isEqualTo(2);
        assertThat(branch.getHeadSeq()).isEqualTo(2);
        assertThat(branch.getState()).isEqualTo(BranchState.BRANCH_STATE_ACTIVE);
        assertThat(branch.getCreatedByAccountId()).isEqualTo(bob.toString());
        assertThat(branch.hasLastChangeAt()).isFalse();
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = 2", branchId))
                .isEqualTo(replayHash(changes));
        // The parent's people, through the parent (no rows of its own); the retry answers the same branch.
        assertThat(count("SELECT count(*) FROM document_member WHERE document_id = ?", branchId)).isZero();
        assertThat(as(BOB).createBranch(request).getBranch().getBranchDocumentId()).isEqualTo(branchId.toString());

        // Ids taken, branches of branches, fork points beyond the head.
        UUID other = document(ALICE);
        assertFails(() -> as(ALICE).createBranch(request.toBuilder().setParentDocumentId(other.toString()).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
        assertFails(() -> as(ALICE).createBranch(create(parent, "Taken").setBranchDocumentId(other.toString()).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
        assertFails(() -> as(BOB).createBranch(create(branchId, "Nested").build()), Status.Code.INVALID_ARGUMENT,
                "VALIDATION_FAILED");
        assertFails(() -> as(BOB).createBranch(create(parent, "Future").setForkServerSeq(9).build()),
                Status.Code.FAILED_PRECONDITION, "HISTORY_UNAVAILABLE");

        // Work on the branch shows as its last change.
        long bobReplica = replicaId();
        push(BOB, null, branchId, change(bobReplica, 1));
        Branch worked = as(CAROL).getBranch(GetBranchRequest.newBuilder().setBranchDocumentId(branchId.toString()).build())
                .getBranch();
        assertThat(worked.getHeadSeq()).isEqualTo(3);
        assertThat(worked.getLastAuthorAccountId()).isEqualTo(bob.toString());
        assertThat(worked.hasLastChangeAt()).isTrue();
        assertFails(() -> as(ALICE).getBranch(GetBranchRequest.newBuilder().setBranchDocumentId(parent.toString()).build()),
                Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");

        // An explicit fork point, with changes already made on the branch (the offline case): the
        // parent replica's unsent changes continue its seqs there.
        Change unsent = a.change("Unsent", DocOps.create(wellKnown(LAYERS), DocOps.path("Three", "")));
        Branch early = as(ALICE).createBranch(create(parent, "Offline").setForkServerSeq(2).addInitialChanges(unsent).build())
                .getBranch();
        assertThat(early.getForkServerSeq()).isEqualTo(2);
        assertThat(early.getHeadSeq()).isEqualTo(3);
        assertThat(value("SELECT last_seq FROM replica WHERE document_id = ? AND replica_id = ?",
                UUID.fromString(early.getBranchDocumentId()), a.replica)).isEqualTo(3L);

        // Listing pages newest first; archived ones only when asked; trashed ones never.
        ListBranchesResponse first = as(CAROL).listBranches(ListBranchesRequest.newBuilder()
                .setParentDocumentId(parent.toString()).setPageSize(1).build());
        assertThat(first.getBranchesList()).extracting(Branch::getName).containsExactly("Offline");
        ListBranchesResponse second = as(CAROL).listBranches(ListBranchesRequest.newBuilder()
                .setParentDocumentId(parent.toString()).setPageSize(1).setCursor(first.getNextCursor()).build());
        assertThat(second.getBranchesList()).extracting(Branch::getName).containsExactly("Autumn palette");
        assertThat(second.getNextCursor()).isEmpty();
        assertFails(() -> as(CAROL).listBranches(ListBranchesRequest.newBuilder().setParentDocumentId(parent.toString())
                .setCursor(com.villagecompute.wiretuner.api.grpc.Cursors.encode("x", branchId.toString())).build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");

        assertThat(as(BOB).renameBranch(RenameBranchRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .setName("Winter palette").build()).getBranch().getName()).isEqualTo("Winter palette");
        assertThat(as(BOB).setBranchState(SetBranchStateRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .setState(BranchState.BRANCH_STATE_ARCHIVED).build()).getBranch().getState())
                .isEqualTo(BranchState.BRANCH_STATE_ARCHIVED);
        assertThat(names(parent, false)).containsExactly("Offline");
        assertThat(names(parent, true)).containsExactly("Offline", "Winter palette");
        assertThat(as(BOB).setBranchState(SetBranchStateRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .setState(BranchState.BRANCH_STATE_ACTIVE).build()).getBranch().getState())
                .isEqualTo(BranchState.BRANCH_STATE_ACTIVE);
        assertFails(() -> as(CAROL).renameBranch(RenameBranchRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .setName("x").build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        as(BOB).deleteBranch(DeleteBranchRequest.newBuilder().setBranchDocumentId(branchId.toString()).build());
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", branchId)).isNotNull();
        assertThat(names(parent, true)).containsExactly("Offline");
    }

    List<String> names(UUID parent, boolean archived) {
        return as(ALICE).listBranches(ListBranchesRequest.newBuilder().setParentDocumentId(parent.toString())
                .setIncludeArchived(archived).build()).getBranchesList().stream().map(Branch::getName).toList();
    }

    @Test
    void aMergeReplaysTheBranchSkippingExcludedNodes() {
        UUID parent = document(ALICE);
        share(parent, bob, "editor");
        share(parent, carol, "viewer");
        DocOps.Author a = new DocOps.Author(replicaId());
        OpId first = a.next();
        Change createFirst = a.change("First", DocOps.create(wellKnown(LAYERS), DocOps.path("First", "")));
        OpId second = a.next();
        Change createSecond = a.change("Second", DocOps.create(wellKnown(LAYERS), DocOps.path("Second", "")));
        push(ALICE, null, parent, createFirst, createSecond);
        Branch branch = as(BOB).createBranch(create(parent, "Rework").build()).getBranch();
        UUID branchId = UUID.fromString(branch.getBranchDocumentId());

        // On the branch: both objects renamed, a new one, and an edit of a node the parent never had.
        DocOps.Author b = new DocOps.Author(replicaId());
        OpId fresh = b.next();
        List<Change> branchWork = List.of(b.change("New", DocOps.create(wellKnown(LAYERS), DocOps.path("Fresh", "")),
                        DocOps.rename(fresh, "Fresh named")),
                b.change("Rename both", DocOps.rename(first, "First (branch)"), DocOps.rename(second, "Second (branch)")),
                b.change("Stray", DocOps.rename(DocOps.id(999, 77), "Nowhere"), DocOps.noop()));
        push(BOB, null, branchId, branchWork.toArray(Change[]::new));
        // Meanwhile in the parent.
        Change parentEdit = a.change("Parent edit", DocOps.rename(second, "Second (main)"));
        long head = push(ALICE, null, parent, parentEdit);

        Subscription watching = subscribe(CAROL, null, parent, replicaId(), head);
        watching.next(ServerFrame.FrameCase.WELCOME);
        assertFails(() -> as(CAROL).mergeBranch(MergeBranchRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> as(ALICE).mergeBranch(MergeBranchRequest.newBuilder().setBranchDocumentId(parent.toString())
                .build()), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");

        MergeBranchResponse merged = as(BOB).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branchId.toString()).setReviewedParentSeq(head).addExcludedNodes(second).build());
        assertThat(merged.getFirstParentSeq()).isEqualTo(head + 1);
        assertThat(merged.getLastParentSeq()).isEqualTo(head + 3);
        assertThat(merged.getDroppedOps()).isEqualTo(1);
        assertThat(merged.getBranch().getState()).isEqualTo(BranchState.BRANCH_STATE_MERGED);
        assertThat(merged.getBranch().getMergedBranchSeq()).isEqualTo(5);
        assertThat(merged.getBranch().getMergedParentSeq()).isEqualTo(head + 3);
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ? AND merged_from_branch_id = ?", parent, branchId))
                .isEqualTo(3);
        // Subscribers see the replay attributed to the branch's author.
        List<SequencedChange> seen = watching.changes(3);
        assertThat(seen).extracting(SequencedChange::getServerSeq).containsExactly(head + 1, head + 2, head + 3);
        assertThat(seen).allMatch(c -> c.getAuthor().getUserId().equals(bob.toString()));

        // The parent's log replays to the merged state: the branch's edits, except the excluded node's.
        Engine state = replay(log(ALICE, parent));
        assertThat(name(state, first)).isEqualTo("First (branch)");
        assertThat(name(state, second)).isEqualTo("Second (main)");
        assertThat(name(state, fresh)).isEqualTo("Fresh named");
        assertThat(log(ALICE, parent).get(4)).isEqualTo(branchWork.get(1).toBuilder().setOps(1, DocOps.noop()).build());
        assertThat(log(ALICE, parent).get(3)).isEqualTo(branchWork.get(0));
        // And the snapshotter reaches the same hash as that replay.
        run(() -> snapshotter.snapshot(parent));
        assertThat(value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = ?", parent, head + 3))
                .isEqualTo(StateHash.hex(state.stateHash()));
    }

    @Test
    void aMergeIsRefusedWhenTheParentMovedUnderTheReview() {
        UUID parent = document(ALICE);
        DocOps.Author a = new DocOps.Author(replicaId());
        OpId node = a.next();
        long reviewed = push(ALICE, null, parent, a.change("Node", DocOps.create(wellKnown(LAYERS), DocOps.path("N", ""))));
        Branch branch = as(ALICE).createBranch(create(parent, "Guarded").build()).getBranch();
        push(ALICE, null, parent, a.change("Later", DocOps.rename(node, "Changed in main")));

        MergeBranchRequest excluding = MergeBranchRequest.newBuilder().setBranchDocumentId(branch.getBranchDocumentId())
                .setReviewedParentSeq(reviewed).addExcludedNodes(node).build();
        assertFails(() -> as(ALICE).mergeBranch(excluding), Status.Code.FAILED_PRECONDITION, "MERGE_STALE");
        DocOps.Author resolver = new DocOps.Author(replicaId());
        MergeBranchRequest resolving = MergeBranchRequest.newBuilder().setBranchDocumentId(branch.getBranchDocumentId())
                .setReviewedParentSeq(reviewed).addResolutions(resolver.change("Use branch", DocOps.rename(node, "Mine")))
                .build();
        assertFails(() -> as(ALICE).mergeBranch(resolving), Status.Code.FAILED_PRECONDITION, "MERGE_STALE");
        // Decisions about nodes the parent did not touch since the review go through: nothing to replay,
        // the resolution lands.
        OpId untouched = DocOps.id(500, 42);
        MergeBranchResponse merged = as(ALICE).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branch.getBranchDocumentId()).setReviewedParentSeq(reviewed).addExcludedNodes(untouched)
                .addResolutions(new DocOps.Author(replicaId()).change("Other", DocOps.rename(DocOps.id(501, 42), "Else")))
                .setKeepOpen(true).build());
        assertThat(merged.getFirstParentSeq()).isEqualTo(3);
        assertThat(merged.getLastParentSeq()).isEqualTo(3);
        assertThat(merged.getBranch().getState()).isEqualTo(BranchState.BRANCH_STATE_ACTIVE);
        // Merging again with nothing new lands nothing.
        MergeBranchResponse empty = as(ALICE).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branch.getBranchDocumentId()).build());
        assertThat(empty.getFirstParentSeq()).isZero();
        assertThat(empty.getLastParentSeq()).isZero();
    }

    @Test
    void aSecondMergeReplaysOnlyTheTailAndResolutionsFollowTheReplay() {
        UUID parent = document(ALICE);
        long parentHead = push(ALICE, null, parent, change(replicaId(), 1));
        Branch branch = as(ALICE).createBranch(create(parent, "Twice").build()).getBranch();
        UUID branchId = UUID.fromString(branch.getBranchDocumentId());
        long b = replicaId();
        push(ALICE, null, branchId, change(b, 1), change(b, 2));
        MergeBranchResponse once = as(ALICE).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branchId.toString()).setKeepOpen(true).build());
        assertThat(once.getLastParentSeq()).isEqualTo(parentHead + 2);

        push(ALICE, null, branchId, change(b, 3));
        long resolver = replicaId();
        MergeBranchResponse twice = as(ALICE).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branchId.toString()).addResolutions(change(resolver, 1)).build());
        assertThat(twice.getFirstParentSeq()).isEqualTo(parentHead + 3);
        assertThat(twice.getLastParentSeq()).isEqualTo(parentHead + 4);
        assertThat(column("SELECT seq FROM change_log WHERE document_id = ? AND replica_id = ? ORDER BY server_seq", parent, b))
                .containsExactly(1L, 2L, 3L);
    }

    @Test
    void aReplayedChangeTheParentAlreadyHoldsIsAConflict() {
        UUID parent = document(ALICE);
        long shared = replicaId();
        push(ALICE, null, parent, change(shared, 1));
        // Kept on a branch offline: the parent replica's next seq, then the parent got another seq 2.
        Branch branch = as(ALICE).createBranch(create(parent, "Kept").addInitialChanges(change(shared, 2, "Kept")).build())
                .getBranch();
        push(ALICE, null, parent, change(shared, 2, "Different"));
        assertFails(() -> as(ALICE).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branch.getBranchDocumentId()).build()), Status.Code.FAILED_PRECONDITION, "REPLICA_CONFLICT");
    }

    @Test
    void aBranchWithTenThousandChangesMergesIntoAParentThatAdvancedTenThousand() {
        UUID parent = document(ALICE);
        DocOps.Author a = new DocOps.Author(replicaId());
        List<OpId> nodes = new ArrayList<>();
        List<Change> seed = new ArrayList<>();
        for (int i = 0; i < 100; i++) {
            nodes.add(a.next());
            seed.add(a.change("Node " + i, DocOps.create(wellKnown(LAYERS), DocOps.path("Node " + i, ""))));
        }
        pushAll(ALICE, null, parent, seed);
        Branch branch = as(ALICE).createBranch(create(parent, "Big").build()).getBranch();
        UUID branchId = UUID.fromString(branch.getBranchDocumentId());

        DocOps.Author onBranch = new DocOps.Author(replicaId());
        DocOps.Author onMain = new DocOps.Author(replicaId());
        List<Change> branchWork = new ArrayList<>();
        List<Change> mainWork = new ArrayList<>();
        for (int i = 0; i < 10_000; i++) {
            branchWork.add(onBranch.change("b" + i, DocOps.rename(nodes.get(i % 100), "branch " + i)));
            mainWork.add(onMain.change("m" + i, DocOps.rename(nodes.get((i * 7) % 100), "main " + i)));
        }
        pushAll(ALICE, null, branchId, branchWork);
        long head = pushAll(ALICE, null, parent, mainWork);

        MergeBranchResponse merged = as(ALICE).mergeBranch(MergeBranchRequest.newBuilder()
                .setBranchDocumentId(branchId.toString()).setReviewedParentSeq(head).build());
        assertThat(merged.getLastParentSeq()).isEqualTo(head + 10_000);

        // A client applying the parent's log, and one merging the branch's changes into its own parent
        // state, reach the server's snapshot hash.
        List<Change> parentLog = log(ALICE, parent);
        Engine client = replay(parentLog);
        Engine merging = replay(parentLog.subList(0, (int) head));
        for (int i = 0; i < branchWork.size(); i++) {
            merging.apply(branchWork.get(i), head + 1 + i);
        }
        run(() -> snapshotter.snapshot(parent));
        String server = (String) value("SELECT state_hash FROM snapshot WHERE document_id = ? AND server_seq = ?", parent,
                head + 10_000);
        assertThat(server).isEqualTo(StateHash.hex(client.stateHash())).isEqualTo(StateHash.hex(merging.stateHash()));
    }
}
