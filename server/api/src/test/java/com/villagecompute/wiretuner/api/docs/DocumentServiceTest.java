package com.villagecompute.wiretuner.api.docs;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.DocumentRole;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.docs.v1.CreateFolderRequest;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteFolderRequest;
import com.villagecompute.wiretuner.docs.v1.Document;
import com.villagecompute.wiretuner.docs.v1.DocumentKind;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.Folder;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.ListRequest;
import com.villagecompute.wiretuner.docs.v1.ListResponse;
import com.villagecompute.wiretuner.docs.v1.ListScope;
import com.villagecompute.wiretuner.docs.v1.MoveToFolderRequest;
import com.villagecompute.wiretuner.docs.v1.RenameFolderRequest;
import com.villagecompute.wiretuner.docs.v1.RenameRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreRequest;
import com.villagecompute.wiretuner.docs.v1.SetTemplateRequest;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * SRV-009: DocumentService's library RPCs through the gRPC surface, per RPC and per role. Explicit
 * shares are written as SQL until ShareService (SRV-010) exists.
 */
@QuarkusTest
class DocumentServiceTest extends ServiceTestSupport {

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    UUID alice;
    UUID bob;
    UUID carol;
    UUID dave;

    @BeforeEach
    void accounts() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        carol = TestUsers.accountId(account, CAROL);
        dave = TestUsers.accountId(account, DAVE);
    }

    Document create(String user, UUID space, UUID folder, String name) {
        CreateRequest.Builder request = CreateRequest.newBuilder()
                .setDocumentId(uuid7().toString()).setSpaceId(space.toString()).setName(name);
        if (folder != null) {
            request.setFolderId(folder.toString());
        }
        return as(docs, user).create(request.build()).getDocument();
    }

    Folder folder(String user, UUID space, UUID parent, String name) {
        CreateFolderRequest.Builder request = CreateFolderRequest.newBuilder().setSpaceId(space.toString()).setName(name);
        if (parent != null) {
            request.setParentFolderId(parent.toString());
        }
        return as(docs, user).createFolder(request.build()).getFolder();
    }

    ListResponse list(String user, ListRequest request) {
        return as(docs, user).list(request);
    }

    static UUID id(Document doc) {
        return UUID.fromString(doc.getId());
    }

    static UUID id(Folder folder) {
        return UUID.fromString(folder.getId());
    }

    // ---------------------------------------------------------------------------------- Create

    @Test
    void createMakesTheCallerOwnerOfAPersonalDocument() {
        UUID device = UUID.randomUUID();
        UUID id = uuid7();
        long replica = replicaId();
        Change initial = change(replica, 1, "Create");
        CreateRequest request = CreateRequest.newBuilder()
                .setDocumentId(id.toString()).setSpaceId(alice.toString()).setName("Poster")
                .setKind(DocumentKind.DOCUMENT_KIND_TYPEFACE).setInitialChange(initial).build();

        Document doc = as(docs, ALICE, device).create(request).getDocument();

        assertThat(doc.getId()).isEqualTo(id.toString());
        assertThat(doc.getSpaceId()).isEqualTo(alice.toString());
        assertThat(doc.getOwnerAccountId()).isEqualTo(alice.toString());
        assertThat(doc.getCreatedByAccountId()).isEqualTo(alice.toString());
        assertThat(doc.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
        assertThat(doc.getKind()).isEqualTo(DocumentKind.DOCUMENT_KIND_TYPEFACE);
        assertThat(doc.getHeadSeq()).isEqualTo(1);
        assertThat(doc.getFolderId()).isEmpty();
        assertThat(doc.hasTrashedAt()).isFalse();
        assertThat(doc.getThumbnailBlob().isEmpty()).isTrue();
        assertThat(count("SELECT count(*) FROM change_log WHERE document_id = ? AND server_seq = 1 AND replica_id = ?",
                id, replica)).isEqualTo(1);
        assertThat(value("SELECT device_id FROM replica WHERE document_id = ? AND replica_id = ?", id, replica))
                .isEqualTo(device);

        // Idempotent: the same call again answers the same document.
        Document again = as(docs, ALICE, device).create(request).getDocument();
        assertThat(again.getId()).isEqualTo(doc.getId());
        assertThat(again.getHeadSeq()).isEqualTo(1);
    }

    @Test
    void createWithoutAnInitialChangeOrDeviceIsEmptyAndRetriable() {
        UUID id = uuid7();
        CreateRequest request = CreateRequest.newBuilder()
                .setDocumentId(id.toString()).setSpaceId(alice.toString()).setName("Blank").build();
        Document doc = as(docs, ALICE).create(request).getDocument();
        assertThat(doc.getHeadSeq()).isZero();
        assertThat(doc.getKind()).isEqualTo(DocumentKind.DOCUMENT_KIND_ILLUSTRATION_MULTI_PAGE);
        assertThat(as(docs, ALICE).create(request).getDocument().getId()).isEqualTo(id.toString());

        // An initial change bound without a wt-device lands on the nil device.
        UUID other = uuid7();
        long replica = replicaId();
        as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(other.toString()).setSpaceId(alice.toString())
                .setName("No device").setInitialChange(change(replica, 1, "c")).build());
        assertThat(value("SELECT device_id FROM replica WHERE document_id = ?", other)).isEqualTo(new UUID(0, 0));
    }

    @Test
    void aTakenIdIsDocumentExists() {
        UUID id = uuid7();
        Change initial = change(replicaId(), 1, "Create");
        CreateRequest request = CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(alice.toString())
                .setName("Mine").setInitialChange(initial).build();
        as(docs, ALICE).create(request);

        // Another space, another caller, other content: all DOCUMENT_EXISTS.
        assertFails(() -> as(docs, BOB).create(request.toBuilder().setSpaceId(bob.toString()).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
        share(id, bob, "editor");
        assertFails(() -> as(docs, BOB).create(request), Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
        assertFails(() -> as(docs, ALICE).create(request.toBuilder()
                .setInitialChange(initial.toBuilder().setLabel("Other")).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");

        // A retry with an initial change of a document created without one.
        UUID blank = uuid7();
        CreateRequest bare = CreateRequest.newBuilder().setDocumentId(blank.toString()).setSpaceId(alice.toString())
                .setName("Bare").build();
        as(docs, ALICE).create(bare);
        assertFails(() -> as(docs, ALICE).create(bare.toBuilder().setInitialChange(initial).build()),
                Status.Code.ALREADY_EXISTS, "DOCUMENT_EXISTS");
    }

    @Test
    void theInitialChangeMustBeTheReplicasFirst() {
        CreateRequest request = CreateRequest.newBuilder().setDocumentId(uuid7().toString())
                .setSpaceId(alice.toString()).setName("Gap").setInitialChange(change(replicaId(), 2, "c")).build();
        assertFails(() -> as(docs, ALICE).create(request), Status.Code.ABORTED, "SEQ_GAP");
    }

    @Test
    void createNeedsTheRightToCreateInTheSpace() {
        assertFails(() -> create(BOB, alice, null, "Intruder"), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");

        UUID team = team(alice, "editor");
        teamMember(team, bob, "member");
        teamMember(team, carol, "guest");
        Document teamDoc = create(BOB, team, null, "Team doc");
        assertThat(teamDoc.getSpaceId()).isEqualTo(team.toString());
        assertThat(teamDoc.getOwnerAccountId()).isEqualTo(bob.toString());
        assertThat(teamDoc.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_OWNER);
        assertFails(() -> create(CAROL, team, null, "Guest doc"), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        exec("UPDATE team SET deleted_at = now() WHERE id = ?", team);
        assertFails(() -> create(ALICE, team, null, "After delete"), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
    }

    @Test
    void createIntoAFolderOfAnotherSpaceIsFolderNotFound() {
        Folder bobs = folder(BOB, bob, null, "Bob's");
        assertFails(() -> create(ALICE, alice, id(bobs), "Misfiled"), Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");
        assertFails(() -> create(ALICE, alice, UUID.randomUUID(), "Nowhere"), Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");
        Folder mine = folder(ALICE, alice, null, "Mine");
        assertThat(create(ALICE, alice, id(mine), "Filed").getFolderId()).isEqualTo(mine.getId());
    }

    // ------------------------------------------------------------------------------------ List

    @Test
    void listPagesAFolderByNameWithItsSubfoldersFirst() {
        Folder root = folder(ALICE, alice, null, "Projects " + UUID.randomUUID());
        Folder sub = folder(ALICE, alice, id(root), "Sub");
        Document c = create(ALICE, alice, id(root), "Cherry");
        Document a = create(ALICE, alice, id(root), "Apple");
        Document b = create(ALICE, alice, id(root), "Banana");
        create(ALICE, alice, id(sub), "Deeper");

        ListRequest first = ListRequest.newBuilder().setSpaceId(alice.toString()).setFolderId(root.getId())
                .setPageSize(2).build();
        ListResponse page1 = list(ALICE, first);
        assertThat(page1.getDocumentsList()).extracting(Document::getName).containsExactly("Apple", "Banana");
        assertThat(page1.getFoldersList()).extracting(Folder::getName).containsExactly("Sub");
        assertThat(page1.getFolders(0).getParentFolderId()).isEqualTo(root.getId());
        assertThat(page1.getNextCursor()).isNotEmpty();

        ListResponse page2 = list(ALICE, first.toBuilder().setCursor(page1.getNextCursor()).build());
        assertThat(page2.getDocumentsList()).extracting(Document::getId).containsExactly(c.getId());
        assertThat(page2.getFoldersList()).isEmpty();
        assertThat(page2.getNextCursor()).isEmpty();
        assertThat(List.of(a.getId(), b.getId())).doesNotContain(c.getId());

        // The root lists the space's top-level folders; the default page size applies.
        ListResponse rootPage = list(ALICE, ListRequest.newBuilder().setSpaceId(alice.toString())
                .setScope(ListScope.LIST_SCOPE_FOLDER).build());
        assertThat(rootPage.getFoldersList()).extracting(Folder::getId).contains(root.getId()).doesNotContain(sub.getId());
    }

    @Test
    void listScopesTrashTemplatesAndSharedWithMe() {
        Document trashed = create(ALICE, alice, null, "Trashed " + UUID.randomUUID());
        Document template = create(ALICE, alice, null, "Template " + UUID.randomUUID());
        as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(trashed.getId()).build());
        as(docs, ALICE).setTemplate(SetTemplateRequest.newBuilder().setDocumentId(template.getId()).setIsTemplate(true).build());

        ListRequest.Builder request = ListRequest.newBuilder().setSpaceId(alice.toString()).setPageSize(100);
        assertThat(ids(list(ALICE, request.setScope(ListScope.LIST_SCOPE_TRASH).build())))
                .contains(trashed.getId()).doesNotContain(template.getId());
        assertThat(ids(list(ALICE, request.setScope(ListScope.LIST_SCOPE_TEMPLATES).build())))
                .contains(template.getId()).doesNotContain(trashed.getId());
        assertThat(ids(list(ALICE, request.setScope(ListScope.LIST_SCOPE_FOLDER).build())))
                .contains(template.getId()).doesNotContain(trashed.getId());

        Document shared = create(ALICE, alice, null, "Shared " + UUID.randomUUID());
        share(id(shared), carol, "viewer");
        ListResponse sharedWithCarol = list(CAROL, ListRequest.newBuilder()
                .setScope(ListScope.LIST_SCOPE_SHARED_WITH_ME).setPageSize(100).build());
        assertThat(sharedWithCarol.getDocumentsList()).filteredOn(d -> d.getId().equals(shared.getId()))
                .singleElement().satisfies(d -> assertThat(d.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER));
        assertThat(ids(sharedWithCarol)).doesNotContain(template.getId());
        assertThat(sharedWithCarol.getFoldersList()).isEmpty();
    }

    @Test
    void listNeedsMembershipOfTheSpaceAndShowsOnlyOpenableDocuments() {
        assertFails(() -> list(DAVE, ListRequest.newBuilder().setSpaceId(alice.toString()).build()),
                Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
        assertFails(() -> list(ALICE, ListRequest.newBuilder().setSpaceId(alice.toString())
                .setFolderId(UUID.randomUUID().toString()).build()), Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");

        UUID team = team(alice, "viewer");
        teamMember(team, carol, "guest");
        teamMember(team, bob, "member");
        folder(ALICE, team, null, "Team folder");
        Document open = create(ALICE, team, null, "Open to the guest");
        Document closed = create(ALICE, team, null, "Closed to the guest");
        share(id(open), carol, "commenter");

        ListRequest request = ListRequest.newBuilder().setSpaceId(team.toString()).build();
        ListResponse guest = list(CAROL, request);
        assertThat(ids(guest)).containsExactly(open.getId());
        assertThat(guest.getDocuments(0).getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_COMMENTER);
        assertThat(guest.getFoldersList()).isEmpty();

        ListResponse member = list(BOB, request);
        assertThat(ids(member)).containsExactlyInAnyOrder(open.getId(), closed.getId());
        assertThat(member.getDocumentsList()).allSatisfy(d ->
                assertThat(d.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER));
        assertThat(member.getFoldersList()).extracting(Folder::getName).containsExactly("Team folder");
    }

    @Test
    void aForeignCursorIsValidationFailed() {
        for (String cursor : new String[] {"!!!", "bm9zZXBhcmF0b3I", "YQ-bm90LWEtdXVpZA"}) {
            assertFails(() -> list(ALICE, ListRequest.newBuilder().setSpaceId(alice.toString()).setCursor(cursor).build()),
                    Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
        }
        String notAUuid = com.villagecompute.wiretuner.api.grpc.Cursors.encode("a", "not-a-uuid");
        assertFails(() -> list(ALICE, ListRequest.newBuilder().setSpaceId(alice.toString()).setCursor(notAUuid).build()),
                Status.Code.INVALID_ARGUMENT, "VALIDATION_FAILED");
    }

    // ------------------------------------------------------------------- Get, Rename, Template

    @Test
    void getRenameAndSetTemplateByRole() {
        Document doc = create(ALICE, alice, null, "Draft name");
        share(id(doc), bob, "editor");
        share(id(doc), carol, "viewer");
        GetRequest get = GetRequest.newBuilder().setDocumentId(doc.getId()).build();

        assertThat(as(docs, CAROL).get(get).getDocument().getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_VIEWER);
        assertFails(() -> as(docs, DAVE).get(get), Status.Code.NOT_FOUND, "DOCUMENT_NOT_FOUND");

        RenameRequest rename = RenameRequest.newBuilder().setDocumentId(doc.getId()).setName("Better name").build();
        assertFails(() -> as(docs, CAROL).rename(rename), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        Document renamed = as(docs, BOB).rename(rename).getDocument();
        assertThat(renamed.getName()).isEqualTo("Better name");
        assertThat(renamed.getCallerRole()).isEqualTo(DocumentRole.DOCUMENT_ROLE_EDITOR);

        SetTemplateRequest template = SetTemplateRequest.newBuilder().setDocumentId(doc.getId()).setIsTemplate(true).build();
        assertFails(() -> as(docs, CAROL).setTemplate(template), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertThat(as(docs, BOB).setTemplate(template).getDocument().getIsTemplate()).isTrue();
        assertThat(as(docs, BOB).setTemplate(template.toBuilder().setIsTemplate(false).build()).getDocument()
                .getIsTemplate()).isFalse();
    }

    // ------------------------------------------------------------------------- Trash, Restore

    @Test
    void trashAndRestoreAreOwnerOnlyAndIdempotent() {
        Document doc = create(ALICE, alice, null, "Short-lived");
        share(id(doc), bob, "editor");
        TrashRequest trash = TrashRequest.newBuilder().setDocumentId(doc.getId()).build();
        assertFails(() -> as(docs, BOB).trash(trash), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        Document trashed = as(docs, ALICE).trash(trash).getDocument();
        assertThat(trashed.hasTrashedAt()).isTrue();
        assertThat(as(docs, ALICE).trash(trash).getDocument().getTrashedAt()).isEqualTo(trashed.getTrashedAt());
        // Get still answers a trashed document.
        assertThat(as(docs, BOB).get(GetRequest.newBuilder().setDocumentId(doc.getId()).build()).getDocument()
                .hasTrashedAt()).isTrue();

        RestoreRequest restore = RestoreRequest.newBuilder().setDocumentId(doc.getId()).build();
        assertFails(() -> as(docs, BOB).restore(restore), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertThat(as(docs, ALICE).restore(restore).getDocument().hasTrashedAt()).isFalse();
        assertThat(as(docs, ALICE).restore(restore).getDocument().hasTrashedAt()).isFalse();
    }

    // ---------------------------------------------------------------------------- MoveToFolder

    @Test
    void moveWithinTheSpaceNeedsAnEditor() {
        Document doc = create(ALICE, alice, null, "Mover");
        share(id(doc), bob, "editor");
        share(id(doc), carol, "viewer");
        Folder target = folder(ALICE, alice, null, "Target");
        MoveToFolderRequest move = MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setFolderId(target.getId()).build();

        assertFails(() -> as(docs, CAROL).moveToFolder(move), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertThat(as(docs, BOB).moveToFolder(move).getDocument().getFolderId()).isEqualTo(target.getId());
        // Naming the current space explicitly is still a move within it; empty folder = the root.
        assertThat(as(docs, BOB).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(alice.toString()).build()).getDocument().getFolderId()).isEmpty();

        Folder elsewhere = folder(BOB, bob, null, "Bob's");
        assertFails(() -> as(docs, BOB).moveToFolder(move.toBuilder().setFolderId(elsewhere.getId()).build()),
                Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");
    }

    @Test
    void moveBetweenSpacesNeedsTheOwnerAndKeepsOneOwner() {
        UUID team = team(bob, "editor");
        teamMember(team, alice, "member");
        Document doc = create(ALICE, alice, null, "Travelling");
        share(id(doc), carol, "viewer");

        MoveToFolderRequest toTeam = MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(team.toString()).build();
        share(id(doc), dave, "editor");
        assertFails(() -> as(docs, DAVE).moveToFolder(toTeam), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");

        // Personal -> team: the owner stays owner as the team document's owner row.
        Document inTeam = as(docs, ALICE).moveToFolder(toTeam).getDocument();
        assertThat(inTeam.getSpaceId()).isEqualTo(team.toString());
        assertThat(inTeam.getOwnerAccountId()).isEqualTo(alice.toString());
        assertThat(value("SELECT role FROM document_member WHERE document_id = ? AND account_id = ?", id(doc), carol))
                .isEqualTo("viewer");

        // Team -> the team owner's personal space (bob holds owner powers as team owner): alice drops to editor.
        Document inBobs = as(docs, BOB).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(bob.toString()).build()).getDocument();
        assertThat(inBobs.getSpaceId()).isEqualTo(bob.toString());
        assertThat(inBobs.getOwnerAccountId()).isEqualTo(bob.toString());
        assertThat(value("SELECT role FROM document_member WHERE document_id = ? AND account_id = ?", id(doc), alice))
                .isEqualTo("editor");

        // A space the owner may not create in.
        UUID foreign = team(dave, "editor");
        assertFails(() -> as(docs, BOB).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(foreign.toString()).build()), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
    }

    @Test
    void movingATeamDocumentHomeByItsOwnerDropsTheOwnerRow() {
        UUID team = team(alice, "editor");
        UUID other = team(alice, "viewer");
        teamMember(team, bob, "member");
        teamMember(other, bob, "member");
        Document doc = create(BOB, team, null, "Bob's team doc");
        MoveToFolderRequest out = MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(other.toString()).build();

        // Moving out of a team needs a team admin (COLLAB-011): the owner row alone is not enough.
        assertFails(() -> as(docs, BOB).moveToFolder(out), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        exec("UPDATE team_member SET role = 'admin' WHERE team_id IN (?, ?) AND account_id = ?", team, other, bob);

        // Team -> team keeps the owner row.
        Document moved = as(docs, BOB).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(other.toString()).build()).getDocument();
        assertThat(moved.getSpaceId()).isEqualTo(other.toString());
        assertThat(moved.getOwnerAccountId()).isEqualTo(bob.toString());

        Document home = as(docs, BOB).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(bob.toString()).build()).getDocument();
        assertThat(home.getOwnerAccountId()).isEqualTo(bob.toString());
        assertThat(count("SELECT count(*) FROM document_member WHERE document_id = ?", id(doc))).isZero();
    }

    @Test
    void aTeamDocumentWithoutAnOwnerRowMovesWithoutOne() {
        UUID team = team(alice, "editor");
        UUID other = team(alice, "editor");
        Document doc = create(ALICE, team, null, "Orphan");
        exec("DELETE FROM document_member WHERE document_id = ?", id(doc));

        Document moved = as(docs, ALICE).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(other.toString()).build()).getDocument();
        assertThat(moved.getOwnerAccountId()).isEmpty();
        Document home = as(docs, ALICE).moveToFolder(MoveToFolderRequest.newBuilder().setDocumentId(doc.getId())
                .setSpaceId(alice.toString()).build()).getDocument();
        assertThat(home.getOwnerAccountId()).isEqualTo(alice.toString());
    }

    // --------------------------------------------------------------------------------- Folders

    @Test
    void foldersNestRenameAndDeleteIntoTheirParent() {
        Folder parent = folder(ALICE, alice, null, "Parent");
        Folder child = folder(ALICE, alice, id(parent), "Child");
        Folder grandchild = folder(ALICE, alice, id(child), "Grandchild");
        Document inChild = create(ALICE, alice, id(child), "In child");
        assertThat(child.getParentFolderId()).isEqualTo(parent.getId());
        assertThat(child.getSpaceId()).isEqualTo(alice.toString());

        Folder renamed = as(docs, ALICE).renameFolder(RenameFolderRequest.newBuilder().setFolderId(child.getId())
                .setName("Renamed").build()).getFolder();
        assertThat(renamed.getName()).isEqualTo("Renamed");

        as(docs, ALICE).deleteFolder(DeleteFolderRequest.newBuilder().setFolderId(child.getId()).build());
        assertThat(value("SELECT folder_id FROM document WHERE id = ?", id(inChild))).isEqualTo(id(parent));
        assertThat(value("SELECT parent_folder_id FROM folder WHERE id = ?", id(grandchild))).isEqualTo(id(parent));
        // Idempotent.
        as(docs, ALICE).deleteFolder(DeleteFolderRequest.newBuilder().setFolderId(child.getId()).build());

        // Deleting a root folder moves its contents to the space's root.
        as(docs, ALICE).deleteFolder(DeleteFolderRequest.newBuilder().setFolderId(parent.getId()).build());
        assertThat(value("SELECT folder_id FROM document WHERE id = ?", id(inChild))).isNull();
    }

    @Test
    void foldersNeedTheRightToCreateInTheirSpace() {
        Folder mine = folder(ALICE, alice, null, "Private");
        assertFails(() -> as(docs, BOB).renameFolder(RenameFolderRequest.newBuilder().setFolderId(mine.getId())
                .setName("Mine now").build()), Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");
        assertFails(() -> as(docs, BOB).deleteFolder(DeleteFolderRequest.newBuilder().setFolderId(mine.getId()).build()),
                Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");
        assertFails(() -> as(docs, ALICE).renameFolder(RenameFolderRequest.newBuilder()
                .setFolderId(UUID.randomUUID().toString()).setName("Ghost").build()), Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");
        assertFails(() -> folder(BOB, alice, null, "Intruder"), Status.Code.NOT_FOUND, "SPACE_NOT_FOUND");
        assertFails(() -> folder(ALICE, alice, UUID.randomUUID(), "Orphan"), Status.Code.NOT_FOUND, "FOLDER_NOT_FOUND");

        UUID team = team(alice, "editor");
        teamMember(team, carol, "guest");
        Folder teamFolder = folder(ALICE, team, null, "Team");
        assertThat(teamFolder.getSpaceId()).isEqualTo(team.toString());
        assertFails(() -> folder(CAROL, team, null, "Guest folder"), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
        assertFails(() -> as(docs, CAROL).renameFolder(RenameFolderRequest.newBuilder().setFolderId(teamFolder.getId())
                .setName("Guest rename").build()), Status.Code.PERMISSION_DENIED, "ROLE_INSUFFICIENT");
    }

    static List<String> ids(ListResponse response) {
        return response.getDocumentsList().stream().map(Document::getId).toList();
    }
}
