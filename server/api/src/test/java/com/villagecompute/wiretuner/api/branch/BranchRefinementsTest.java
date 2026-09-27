package com.villagecompute.wiretuner.api.branch;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.history.DocOps.LAYERS;
import static com.villagecompute.wiretuner.api.history.DocOps.wellKnown;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.history.Compactor;
import com.villagecompute.wiretuner.api.history.DocOps;
import com.villagecompute.wiretuner.api.history.HistoryTestSupport;
import com.villagecompute.wiretuner.api.history.Snapshotter;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.docs.v1.Branch;
import com.villagecompute.wiretuner.docs.v1.BranchServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.BranchState;
import com.villagecompute.wiretuner.docs.v1.ChangeSummary;
import com.villagecompute.wiretuner.docs.v1.CreateBranchRequest;
import com.villagecompute.wiretuner.docs.v1.CreateFolderRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteBranchRequest;
import com.villagecompute.wiretuner.docs.v1.HistoryRow;
import com.villagecompute.wiretuner.docs.v1.ListHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.ListMembersRequest;
import com.villagecompute.wiretuner.docs.v1.ListNodeHistoryRequest;
import com.villagecompute.wiretuner.docs.v1.MergeBranchRequest;
import com.villagecompute.wiretuner.docs.v1.MoveToFolderRequest;
import com.villagecompute.wiretuner.docs.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.docs.v1.RenameBranchRequest;
import com.villagecompute.wiretuner.docs.v1.RequestAccessRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreRequest;
import com.villagecompute.wiretuner.docs.v1.Session;
import com.villagecompute.wiretuner.docs.v1.SetBranchStateRequest;
import com.villagecompute.wiretuner.docs.v1.SetRoleRequest;
import com.villagecompute.wiretuner.docs.v1.ShareServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;
import com.villagecompute.wiretuner.docs.v1.VersionServiceGrpc;
import com.villagecompute.wiretuner.sync.v1.BranchEvent;
import com.villagecompute.wiretuner.sync.v1.BranchEventKind;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;
import com.villagecompute.wiretuner.sync.v1.PresenceUpdate;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;
import com.villagecompute.wiretuner.sync.v1.SequencedChange;
import com.villagecompute.wiretuner.sync.v1.ServerFrame.FrameCase;
import com.villagecompute.wiretuner.sync.v1.SubscribeRequest;
import com.villagecompute.wiretuner.sync.v1.UpdatePresenceRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * COLLAB-019 (and the branch halves of COLLAB-004/005/020): branch events on both sides' sessions,
 * roles looked up through the parent, trash, restore and moves following the parent, presence shared
 * between a document and its branches, and a merged change's author and branch in the parent's log
 * and history, hot and cold.
 */
@QuarkusTest
class BranchRefinementsTest extends HistoryTestSupport {

    @GrpcClient("branches")
    BranchServiceGrpc.BranchServiceBlockingStub branches;

    @GrpcClient("share")
    ShareServiceGrpc.ShareServiceBlockingStub share;

    @GrpcClient("versions")
    VersionServiceGrpc.VersionServiceBlockingStub versions;

    @Inject
    Snapshotter snapshotter;

    @Inject
    Compactor compactor;

    BranchServiceGrpc.BranchServiceBlockingStub as(String user) {
        return TestUsers.as(branches, user);
    }

    UUID branch(String user, UUID parent, String name, Change... initial) {
        return UUID.fromString(as(user).createBranch(CreateBranchRequest.newBuilder().setParentDocumentId(parent.toString())
                .setBranchDocumentId(uuid7().toString()).setName(name).addAllInitialChanges(List.of(initial)).build())
                .getBranch().getBranchDocumentId());
    }

    Subscription watch(String user, UUID document) {
        Subscription s = subscribe(user, null, document, replicaId(), 0);
        s.next(FrameCase.PRESENCE);
        return s;
    }

    static DocumentEvent event(Subscription s, DocumentEvent.EventCase kind) {
        while (true) {
            DocumentEvent event = s.next(FrameCase.EVENT).getEvent();
            if (event.getEventCase() == kind) {
                return event;
            }
        }
    }

    static BranchEvent branchEvent(Subscription s) {
        return event(s, DocumentEvent.EventCase.BRANCH).getBranch();
    }

    @Test
    void everyBranchChangeIsToldToTheParentsAndTheBranchsSessions() {
        UUID parent = document(ALICE);
        share(parent, bob, "editor");
        push(ALICE, null, parent, change(replicaId(), 1));
        Subscription onParent = watch(BOB, parent);
        UUID branchId = branch(ALICE, parent, "Events");
        BranchEvent created = branchEvent(onParent);
        assertThat(created.getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_CREATED);
        assertThat(created.getBranchDocumentId()).isEqualTo(branchId.toString());
        assertThat(created.getParentDocumentId()).isEqualTo(parent.toString());
        assertThat(created.getName()).isEqualTo("Events");
        assertThat(created.getActor().getUserId()).isEqualTo(alice.toString());
        Subscription onBranch = watch(BOB, branchId);

        as(BOB).renameBranch(RenameBranchRequest.newBuilder().setBranchDocumentId(branchId.toString()).setName("Renamed").build());
        for (Subscription s : List.of(onParent, onBranch)) {
            BranchEvent renamed = branchEvent(s);
            assertThat(renamed.getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_RENAMED);
            assertThat(renamed.getName()).isEqualTo("Renamed");
            assertThat(renamed.getActor().getUserId()).isEqualTo(bob.toString());
        }
        as(BOB).setBranchState(SetBranchStateRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .setState(BranchState.BRANCH_STATE_ARCHIVED).build());
        assertThat(branchEvent(onParent).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_ARCHIVED);
        assertThat(branchEvent(onBranch).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_ARCHIVED);
        as(BOB).setBranchState(SetBranchStateRequest.newBuilder().setBranchDocumentId(branchId.toString())
                .setState(BranchState.BRANCH_STATE_ACTIVE).build());
        assertThat(branchEvent(onParent).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_RESTORED);
        assertThat(branchEvent(onBranch).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_RESTORED);
        push(BOB, null, branchId, change(replicaId(), 1));
        as(BOB).mergeBranch(MergeBranchRequest.newBuilder().setBranchDocumentId(branchId.toString()).setKeepOpen(true).build());
        assertThat(branchEvent(onParent).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_MERGED);
        assertThat(branchEvent(onBranch).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_MERGED);
        as(BOB).deleteBranch(DeleteBranchRequest.newBuilder().setBranchDocumentId(branchId.toString()).build());
        assertThat(branchEvent(onParent).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_TRASHED);
        assertThat(branchEvent(onBranch).getKind()).isEqualTo(BranchEventKind.BRANCH_EVENT_KIND_TRASHED);
        onParent.cancel();
        onBranch.cancel();
    }

    @Test
    void aBranchsRolesAreItsParentsLookedUpLive() {
        UUID parent = document(ALICE);
        share(parent, bob, "editor");
        UUID branchId = branch(ALICE, parent, "Roles");
        long bobs = replicaId();
        push(BOB, null, branchId, change(bobs, 1));
        Subscription onBranch = watch(BOB, branchId);
        // No role rows of its own, colors included: Bob's color lives on the parent.
        assertThat(count("SELECT count(*) FROM document_member WHERE document_id = ?", branchId)).isZero();
        assertThat(value("SELECT color_index FROM document_member WHERE document_id = ? AND account_id = ?", parent, bob))
                .isNotNull();

        ShareServiceGrpc.ShareServiceBlockingStub owner = TestUsers.as(share, ALICE);
        owner.setRole(SetRoleRequest.newBuilder().setDocumentId(parent.toString()).setAccountId(bob.toString())
                .setRole(DocumentRole.DOCUMENT_ROLE_VIEWER).build());
        assertThat(event(onBranch, DocumentEvent.EventCase.ROLE_CHANGED).getRoleChanged().getRole())
                .isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
        assertFails(() -> push(BOB, null, branchId, change(bobs, 2)), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        owner.removeMember(RemoveMemberRequest.newBuilder().setDocumentId(parent.toString()).setAccountId(bob.toString())
                .build());
        event(onBranch, DocumentEvent.EventCase.ACCESS_REMOVED);
        assertFails(() -> blocking(BOB, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(branchId.toString())
                .setChange(change(bobs, 2)).build()), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");

        // A branch's people are its parent's: its sharing is its parent's.
        assertFails(() -> owner.listMembers(ListMembersRequest.newBuilder().setDocumentId(branchId.toString()).build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
        assertFails(() -> TestUsers.as(share, CAROL).requestAccess(RequestAccessRequest.newBuilder()
                .setDocumentId(branchId.toString()).build()), Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    @Test
    void branchesGoToTheTrashComeBackAndMoveWithTheirParent() {
        UUID parent = document(ALICE);
        UUID following = branch(ALICE, parent, "Following");
        UUID alone = branch(ALICE, parent, "Alone");
        as(ALICE).deleteBranch(DeleteBranchRequest.newBuilder().setBranchDocumentId(alone.toString()).build());
        Object aloneTrashed = value("SELECT trashed_at FROM document WHERE id = ?", alone);
        Subscription onBranch = watch(ALICE, following);

        TestUsers.as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(parent.toString()).build());
        assertThat(event(onBranch, DocumentEvent.EventCase.TRASHED).getTrashed().getTrashed()).isTrue();
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", following))
                .isEqualTo(value("SELECT trashed_at FROM document WHERE id = ?", parent));
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", alone)).isEqualTo(aloneTrashed);
        // Trashing again changes nothing.
        TestUsers.as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(parent.toString()).build());

        TestUsers.as(docs, ALICE).restore(RestoreRequest.newBuilder().setDocumentId(parent.toString()).build());
        assertThat(event(onBranch, DocumentEvent.EventCase.TRASHED).getTrashed().getTrashed()).isFalse();
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", following)).isNull();
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", alone)).isEqualTo(aloneTrashed);
        // Restoring what is not in the trash changes nothing.
        TestUsers.as(docs, ALICE).restore(RestoreRequest.newBuilder().setDocumentId(parent.toString()).build());

        UUID folder = UUID.fromString(TestUsers.as(docs, ALICE).createFolder(CreateFolderRequest.newBuilder()
                .setSpaceId(alice.toString()).setName("Moved").build()).getFolder().getId());
        TestUsers.as(docs, ALICE).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(parent.toString())
                .setFolderId(folder.toString()).build());
        assertThat(event(onBranch, DocumentEvent.EventCase.MOVED).getMoved().getFolderId()).isEqualTo(folder.toString());
        assertThat(value("SELECT folder_id FROM document WHERE id = ?", following)).isEqualTo(folder);
        onBranch.cancel();
    }

    static PresenceUpdate presenceOf(Subscription s, UUID user) {
        while (true) {
            PresenceUpdate update = s.next(FrameCase.PRESENCE_UPDATE).getPresenceUpdate();
            if (update.getUser().getUserId().equals(user.toString())) {
                return update;
            }
        }
    }

    @Test
    void aDocumentAndItsBranchesShareOnePresence() {
        UUID parent = document(ALICE);
        share(parent, bob, "editor");
        UUID branchId = branch(ALICE, parent, "Together");
        long alices = replicaId();
        Subscription onParent = subscribe(ALICE, null, SubscribeRequest.newBuilder().setDocumentId(parent.toString())
                .setReplica(alices).setPresence(PresenceUpdate.newBuilder().setTool("pen")).build());
        onParent.next(FrameCase.PRESENCE);
        long bobs = replicaId();
        Subscription onBranch = subscribe(BOB, null, SubscribeRequest.newBuilder().setDocumentId(branchId.toString())
                .setReplica(bobs).setPresence(PresenceUpdate.newBuilder().setTool("brush")
                        .setBranchId(parent.toString())).build());
        // The branch's snapshot lists the parent's session, and its own with the branch set.
        List<PresenceUpdate> seen = onBranch.next(FrameCase.PRESENCE).getPresence().getParticipantsList();
        assertThat(seen).extracting(PresenceUpdate::getTool).containsExactlyInAnyOrder("pen", "brush");
        PresenceUpdate alicesEntry = seen.stream().filter(p -> p.getTool().equals("pen")).findFirst().orElseThrow();
        assertThat(alicesEntry.getBranchId()).isEmpty();
        assertThat(alicesEntry.getSession()).isEqualTo(alices);
        // The parent's session sees the branch's, with the branch named.
        PresenceUpdate bobsEntry = presenceOf(onParent, bob);
        assertThat(bobsEntry.getBranchId()).isEqualTo(branchId.toString());
        assertThat(bobsEntry.getSession()).isEqualTo(bobs);
        assertThat(bobsEntry.getColorIndex()).isEqualTo(((Number) value(
                "SELECT color_index FROM document_member WHERE document_id = ? AND account_id = ?", parent, bob)).intValue());

        // Updates travel both ways; the parent's changes do not reach the branch.
        blocking(BOB, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(branchId.toString())
                .setReplica(bobs).setPresence(PresenceUpdate.newBuilder().setTool("lasso")).build());
        assertThat(presenceOf(onParent, bob).getTool()).isEqualTo("lasso");
        blocking(ALICE, null).updatePresence(UpdatePresenceRequest.newBuilder().setDocumentId(parent.toString())
                .setReplica(alices).setPresence(PresenceUpdate.newBuilder().setTool("zoom")).build());
        assertThat(presenceOf(onBranch, alice).getTool()).isEqualTo("zoom");
        push(ALICE, null, parent, change(alices, 1));
        onBranch.assertNoChange(Duration.ofMillis(500));

        onBranch.cancel();
        PresenceUpdate gone = presenceOf(onParent, bob);
        assertThat(gone.getState()).isEqualTo(com.villagecompute.wiretuner.sync.v1.PresenceState.PRESENCE_STATE_GONE);
        assertThat(gone.getBranchId()).isEqualTo(branchId.toString());
        onParent.cancel();
    }

    List<SequencedChange> log(UUID document) {
        List<SequencedChange> changes = new java.util.ArrayList<>();
        blocking(ALICE, null).fetchChanges(FetchChangesRequest.newBuilder().setDocumentId(document.toString()).build())
                .forEachRemaining(page -> changes.addAll(page.getChangesList()));
        return changes;
    }

    @Test
    void aMergedChangeKeepsItsAuthorAndBranchInTheParentsLogAndHistoryHotAndCold() {
        UUID parent = document(ALICE);
        share(parent, bob, "editor");
        DocOps.Author a = new DocOps.Author(replicaId());
        OpId logo = a.next();
        push(ALICE, null, parent, a.change("Logo", DocOps.create(wellKnown(LAYERS), DocOps.path("Logo", ""))));
        // A branch whose history names the parent's node by the parent's name for it.
        DocOps.Author b = new DocOps.Author(replicaId());
        UUID branchId = branch(BOB, parent, "Side", b.change("Kept", DocOps.rename(logo, "Logo (side)")));
        ChangeSummary kept = TestUsers.as(versions, BOB).listNodeHistory(ListNodeHistoryRequest.newBuilder()
                .setDocumentId(branchId.toString()).setNode(logo).build()).getChanges(0);
        assertThat(kept.getLabel()).isEqualTo("Kept");
        assertThat(kept.getNodes(0).getName()).isEqualTo("Logo (side)");
        List<Change> work = new java.util.ArrayList<>();
        for (int i = 0; i < 3; i++) {
            work.add(b.change("Side " + i, DocOps.rename(logo, "Side " + i)));
        }
        push(BOB, null, branchId, work.toArray(Change[]::new));
        as(BOB).mergeBranch(MergeBranchRequest.newBuilder().setBranchDocumentId(branchId.toString()).build());
        for (int i = 0; i < 6; i++) {
            push(ALICE, null, parent, a.change("Main " + i, DocOps.noop()));
        }
        List<SequencedChange> hot = log(parent);
        assertThat(hot.subList(1, 5)).isNotEmpty().allMatch(c -> c.getAuthor().getUserId().equals(bob.toString()));

        run(() -> snapshotter.snapshot(parent));
        assertThat(run(() -> compactor.compact(parent))).isPositive();
        assertThat(count("SELECT min(server_seq) FROM change_log WHERE document_id = ?", parent)).isGreaterThan(5);
        List<SequencedChange> cold = log(parent);
        assertThat(cold.subList(1, 5)).isNotEmpty().allMatch(c -> c.getAuthor().getUserId().equals(bob.toString()));

        List<HistoryRow> rows = TestUsers.as(versions, ALICE).listHistory(ListHistoryRequest.newBuilder()
                .setDocumentId(parent.toString()).build()).getRowsList();
        Session merged = rows.stream().map(HistoryRow::getSession)
                .filter(s -> s.getMergedFromBranchId().equals(branchId.toString())).findFirst().orElseThrow();
        assertThat(merged.getAuthor().getUserId()).isEqualTo(bob.toString());
        assertThat(merged.getMergedFromBranchName()).isEqualTo("Side");
        assertThat(merged.getChangeCount()).isEqualTo(4);
        assertThat(merged.getChangesList()).extracting(ChangeSummary::getLabel)
                .containsExactly("Side 2", "Side 1", "Side 0", "Kept");
        assertThat(merged.getChanges(0).getNodes(0).getName()).isEqualTo("Side 2");
    }
}
