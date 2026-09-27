package com.villagecompute.wiretuner.api.branch;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.docs.v1.Branch;
import com.villagecompute.wiretuner.docs.v1.BranchServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.BranchState;
import com.villagecompute.wiretuner.docs.v1.CreateBranchRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteBranchRequest;
import com.villagecompute.wiretuner.docs.v1.Document;
import com.villagecompute.wiretuner.docs.v1.ListBranchesRequest;
import com.villagecompute.wiretuner.docs.v1.ListBranchesResponse;
import com.villagecompute.wiretuner.docs.v1.ListRequest;
import com.villagecompute.wiretuner.docs.v1.ListScope;
import com.villagecompute.wiretuner.docs.v1.RestoreRequest;
import com.villagecompute.wiretuner.docs.v1.SetBranchStateRequest;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * COLLAB-016's library window on the server: every branch of a space's documents in one
 * {@code ListBranches} (the nesting and the Archived list), and branches trashed on their own in the
 * space's trash (the Trash list), restorable like any document.
 */
@QuarkusTest
class BranchLibraryTest extends SyncTestSupport {

    @GrpcClient("branches")
    BranchServiceGrpc.BranchServiceBlockingStub branches;

    BranchServiceGrpc.BranchServiceBlockingStub as(String user) {
        return TestUsers.as(branches, user);
    }

    UUID branch(String user, UUID parent, String name) {
        return UUID.fromString(as(user).createBranch(CreateBranchRequest.newBuilder().setParentDocumentId(parent.toString())
                .setBranchDocumentId(uuid7().toString()).setName(name).build()).getBranch().getBranchDocumentId());
    }

    List<String> names(ListBranchesResponse response) {
        return response.getBranchesList().stream().map(Branch::getName).toList();
    }

    ListBranchesResponse inSpace(String user, UUID space, boolean archived) {
        return as(user).listBranches(ListBranchesRequest.newBuilder().setSpaceId(space.toString()).setIncludeArchived(archived).build());
    }

    List<Document> trash(String user, UUID space) {
        return TestUsers.as(docs, user).list(ListRequest.newBuilder().setSpaceId(space.toString())
                .setScope(ListScope.LIST_SCOPE_TRASH).build()).getDocumentsList();
    }

    @Test
    void aSpacesBranchesComeInOneListNewestFirstWithArchivedOnesWhenAsked() {
        UUID space = TestUsers.accountId(account, ALICE);
        UUID catalogue = document(ALICE);
        UUID poster = document(ALICE);
        UUID autumn = branch(ALICE, catalogue, "Autumn");
        branch(ALICE, catalogue, "Winter");
        UUID cover = branch(ALICE, poster, "Cover");
        as(ALICE).setBranchState(SetBranchStateRequest.newBuilder().setBranchDocumentId(cover.toString())
                .setState(BranchState.BRANCH_STATE_ARCHIVED).build());

        assertThat(names(inSpace(ALICE, space, false))).containsSubsequence("Winter", "Autumn").doesNotContain("Cover");
        ListBranchesResponse all = inSpace(ALICE, space, true);
        assertThat(names(all)).containsSubsequence("Cover", "Winter", "Autumn");
        Branch archived = all.getBranchesList().stream().filter(b -> b.getName().equals("Cover")).findFirst().orElseThrow();
        assertThat(archived.getParentDocumentId()).isEqualTo(poster.toString());
        assertThat(archived.getState()).isEqualTo(BranchState.BRANCH_STATE_ARCHIVED);

        // Pages follow the cursor.
        ListBranchesResponse first = as(ALICE).listBranches(ListBranchesRequest.newBuilder().setSpaceId(space.toString())
                .setIncludeArchived(true).setPageSize(1).build());
        assertThat(first.getBranchesCount()).isEqualTo(1);
        ListBranchesResponse second = as(ALICE).listBranches(ListBranchesRequest.newBuilder().setSpaceId(space.toString())
                .setIncludeArchived(true).setPageSize(1).setCursor(first.getNextCursor()).build());
        assertThat(second.getBranches(0).getBranchDocumentId()).isNotEqualTo(first.getBranches(0).getBranchDocumentId());

        // A trashed branch, or one whose parent is trashed, is not listed.
        as(ALICE).deleteBranch(DeleteBranchRequest.newBuilder().setBranchDocumentId(autumn.toString()).build());
        TestUsers.as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(poster.toString()).build());
        assertThat(names(inSpace(ALICE, space, true))).contains("Winter").doesNotContain("Autumn", "Cover");
    }

    @Test
    void onlyMembersOfTheSpaceListItsBranches() {
        UUID team = team(alice(), "editor");
        teamMember(team, TestUsers.accountId(account, BOB), "member");
        UUID shared = uuid7();
        TestUsers.as(docs, ALICE).create(com.villagecompute.wiretuner.docs.v1.CreateRequest.newBuilder()
                .setDocumentId(shared.toString()).setSpaceId(team.toString()).setName("Team doc").build());
        branch(ALICE, shared, "Team branch");
        assertThat(names(inSpace(BOB, team, true))).containsExactly("Team branch");
        // Carol is not in the team, and nobody lists another person's personal space.
        assertFails(() -> inSpace(CAROL, team, true), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
        assertFails(() -> inSpace(BOB, alice(), true), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
        // Neither or both of parent and space is refused.
        assertFails(() -> as(ALICE).listBranches(ListBranchesRequest.getDefaultInstance()), Status.Code.INVALID_ARGUMENT,
                "VALIDATION_FAILED");
        assertFails(() -> as(ALICE).listBranches(ListBranchesRequest.newBuilder().setSpaceId(team.toString())
                .setParentDocumentId(shared.toString()).build()), Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    @Test
    void aBranchTrashedOnItsOwnIsInTheTrashWithItsParentAndComesBackWithRestore() {
        UUID space = TestUsers.accountId(account, ALICE);
        UUID parent = document(ALICE);
        UUID alone = branch(ALICE, parent, "Alone");
        UUID following = branch(ALICE, parent, "Following");
        as(ALICE).deleteBranch(DeleteBranchRequest.newBuilder().setBranchDocumentId(alone.toString()).build());

        Document listed = trash(ALICE, space).stream().filter(d -> d.getId().equals(alone.toString())).findFirst().orElseThrow();
        assertThat(listed.getParentDocumentId()).isEqualTo(parent.toString());
        assertThat(listed.hasTrashedAt()).isTrue();
        // A folder listing never shows branches.
        assertThat(TestUsers.as(docs, ALICE).list(ListRequest.newBuilder().setSpaceId(space.toString()).build())
                .getDocumentsList().stream().map(Document::getId)).doesNotContain(alone.toString(), following.toString());

        // Trashing the parent lists the parent; the branch that went with it is not listed apart from it.
        TestUsers.as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(parent.toString()).build());
        assertThat(trash(ALICE, space).stream().map(Document::getId)).contains(parent.toString(), alone.toString())
                .doesNotContain(following.toString());
        TestUsers.as(docs, ALICE).restore(RestoreRequest.newBuilder().setDocumentId(parent.toString()).build());

        TestUsers.as(docs, ALICE).restore(RestoreRequest.newBuilder().setDocumentId(alone.toString()).build());
        assertThat(trash(ALICE, space).stream().map(Document::getId)).doesNotContain(alone.toString());
        assertThat(names(inSpace(ALICE, space, false))).contains("Alone", "Following");
    }

    UUID alice() {
        return TestUsers.accountId(account, ALICE);
    }
}
