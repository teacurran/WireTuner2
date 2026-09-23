package com.villagecompute.wiretuner.api.library;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.sync.SyncTestSupport;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentKind;
import com.villagecompute.wiretuner.docs.v1.GetLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.Library;
import com.villagecompute.wiretuner.docs.v1.LibraryServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.ListLibrariesRequest;
import com.villagecompute.wiretuner.docs.v1.ListLibrariesResponse;
import com.villagecompute.wiretuner.docs.v1.SetLibraryRequest;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;
import com.villagecompute.wiretuner.sync.v1.PushChangeRequest;

import io.grpc.Status;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * COLLAB-012: publishing and unpublishing team libraries, listing them per team for members (not
 * guests), GetLibrary's head_seq for update checks, and a member reading a library's content.
 */
@QuarkusTest
class LibraryServiceTest extends SyncTestSupport {

    @GrpcClient("library")
    LibraryServiceGrpc.LibraryServiceBlockingStub libraries;

    UUID dave;

    @BeforeEach
    void more() {
        dave = TestUsers.accountId(account, DAVE);
    }

    LibraryServiceGrpc.LibraryServiceBlockingStub by(String user) {
        return TestUsers.as(libraries, user);
    }

    UUID teamDocument(UUID team, String name) {
        UUID id = uuid7();
        TestUsers.as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(team.toString())
                .setName(name).build());
        return id;
    }

    Library publish(String user, UUID doc, String name) {
        return by(user).setLibrary(SetLibraryRequest.newBuilder().setDocumentId(doc.toString()).setIsLibrary(true)
                .setName(name).build()).getLibrary();
    }

    List<Library> list(String user, UUID team, int pageSize) {
        List<Library> all = new ArrayList<>();
        ListLibrariesRequest.Builder request = ListLibrariesRequest.newBuilder().setTeamId(team.toString()).setPageSize(pageSize);
        ListLibrariesResponse page;
        do {
            page = by(user).listLibraries(request.build());
            all.addAll(page.getLibrariesList());
            request.setCursor(page.getNextCursor());
        } while (!page.getNextCursor().isEmpty());
        return all;
    }

    @Test
    void membersSeeTheTeamsLibrariesAndGuestsDoNot() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        teamMember(team, carol, "guest");
        UUID brand = teamDocument(team, "Brand colors");
        UUID icons = teamDocument(team, "Icons");
        teamDocument(team, "Not a library");

        Library published = publish(ALICE, brand, "");
        assertThat(published.getName()).isEqualTo("Brand colors");
        assertThat(published.getTeamId()).isEqualTo(team.toString());
        assertThat(published.getKind()).isEqualTo(DocumentKind.DOCUMENT_KIND_ILLUSTRATION_MULTI_PAGE);
        assertThat(published.getPublishedByAccountId()).isEqualTo(alice.toString());
        assertThat(published.hasPublishedAt()).isTrue();
        publish(ALICE, icons, "Icon set");
        // Publishing again renames it.
        assertThat(publish(ALICE, icons, "Icons v2").getName()).isEqualTo("Icons v2");
        assertThat(TestUsers.as(docs, BOB).get(GetRequest.newBuilder().setDocumentId(brand.toString()).build())
                .getDocument().getIsLibrary()).isTrue();

        assertThat(list(BOB, team, 1)).extracting(Library::getName).containsExactly("Brand colors", "Icons v2");
        assertThat(list(ALICE, team, 0)).hasSize(2);
        assertFails(() -> list(CAROL, team, 0), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> list(DAVE, team, 0), Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);

        // A member reads the library's content; a guest cannot.
        long replica = replicaId();
        blocking(ALICE, null).pushChange(PushChangeRequest.newBuilder().setDocumentId(brand.toString())
                .setChange(change(replica, 1)).build());
        assertThat(blocking(BOB, null).fetchChanges(FetchChangesRequest.newBuilder().setDocumentId(brand.toString()).build())
                .next().getChangesCount()).isEqualTo(1);
        assertFails(() -> blocking(CAROL, null).fetchChanges(FetchChangesRequest.newBuilder()
                .setDocumentId(brand.toString()).build()).next(), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        Library got = by(BOB).getLibrary(GetLibraryRequest.newBuilder().setDocumentId(brand.toString()).build()).getLibrary();
        assertThat(got.getHeadSeq()).isEqualTo(1);

        // Unpublishing removes it from the list; documents that copied from it are not touched (nothing is).
        assertThat(by(ALICE).setLibrary(SetLibraryRequest.newBuilder().setDocumentId(brand.toString()).build()).hasLibrary())
                .isFalse();
        assertThat(by(ALICE).setLibrary(SetLibraryRequest.newBuilder().setDocumentId(brand.toString()).build()).hasLibrary())
                .isFalse();
        assertThat(list(BOB, team, 0)).extracting(Library::getName).containsExactly("Icons v2");
        assertFails(() -> by(BOB).getLibrary(GetLibraryRequest.newBuilder().setDocumentId(brand.toString()).build()),
                Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
    }

    @Test
    void onlyTeamDocumentsByTheirOwnersBecomeLibraries() {
        UUID team = team(alice, "editor");
        teamMember(team, bob, "member");
        UUID doc = teamDocument(team, "Styles");
        assertFails(() -> publish(BOB, doc, ""), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        UUID personal = document(ALICE);
        assertFails(() -> publish(ALICE, personal, ""), Status.Code.FAILED_PRECONDITION, ErrorReasons.TEAM_ROLE_INVALID);

        // A thumbnail is reported; a publisher whose account is gone reads as unset.
        exec("INSERT INTO blob (sha256, size_bytes, media_type, storage_key) VALUES (?, 1, 'image/png', 'k')"
                + " ON CONFLICT DO NOTHING", "ab".repeat(32));
        exec("UPDATE document SET thumbnail_blob = ? WHERE id = ?", "ab".repeat(32), doc);
        publish(ALICE, doc, "Styles");
        exec("UPDATE library SET published_by = NULL WHERE document_id = ?", doc);
        Library got = by(BOB).getLibrary(GetLibraryRequest.newBuilder().setDocumentId(doc.toString()).build()).getLibrary();
        assertThat(got.getThumbnailBlob().size()).isEqualTo(32);
        assertThat(got.getPublishedByAccountId()).isEmpty();
        // A trashed library is not listed.
        exec("UPDATE document SET trashed_at = now() WHERE id = ?", doc);
        assertThat(list(BOB, team, 0)).isEmpty();
    }
}
