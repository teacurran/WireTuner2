package com.villagecompute.wiretuner.api.library;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.library.SwatchOps.cmyk;
import static com.villagecompute.wiretuner.api.library.SwatchOps.color;
import static com.villagecompute.wiretuner.api.library.SwatchOps.recolor;
import static com.villagecompute.wiretuner.api.library.SwatchOps.rgb;
import static org.assertj.core.api.Assertions.assertThat;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.PerfReport;
import com.villagecompute.wiretuner.api.PerfTest;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.history.DocOps;
import com.villagecompute.wiretuner.api.history.DocOps.Author;
import com.villagecompute.wiretuner.api.history.HistoryTestSupport;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Op;
import com.villagecompute.wiretuner.doc.v1.OpId;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryInfo;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryMode;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.FetchColorLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.FetchColorLibraryResponse;
import com.villagecompute.wiretuner.docs.v1.ListColorLibrariesRequest;
import com.villagecompute.wiretuner.docs.v1.ListColorLibrariesResponse;
import com.villagecompute.wiretuner.docs.v1.PublishColorLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreRequest;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;
import com.villagecompute.wiretuner.docs.v1.UnpublishColorLibraryRequest;
import com.villagecompute.wiretuner.lib.v1.LibraryColor;
import com.villagecompute.wiretuner.sync.v1.FetchChangesRequest;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;

/**
 * COLOR-020 end to end: publishing a document's colors to a team (owner only, own team or a team
 * the owner of a personal document belongs to), automatic and manual versions, listing and fetching
 * for team members only, unpublishing and trashing leaving the document untouched, and the Fetch
 * budget on a 5,000-swatch library.
 */
@QuarkusTest
class ColorLibraryServiceTest extends HistoryTestSupport {

    @GrpcClient("library")
    ColorLibraryServiceGrpc.ColorLibraryServiceBlockingStub colors;

    UUID dave;

    @BeforeEach
    void more() {
        dave = TestUsers.accountId(account, DAVE);
    }

    ColorLibraryServiceGrpc.ColorLibraryServiceBlockingStub by(String user) {
        return TestUsers.as(colors, user);
    }

    UUID teamDocument(UUID team, String name) {
        UUID id = uuid7();
        TestUsers.as(docs, ALICE).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(team.toString())
                .setName(name).build());
        return id;
    }

    ColorLibraryInfo publish(String user, UUID doc, PublishColorLibraryRequest.Builder request) {
        return by(user).publishColorLibrary(request.setDocumentId(doc.toString()).build()).getLibrary();
    }

    ColorLibraryInfo publish(String user, UUID doc) {
        return publish(user, doc, PublishColorLibraryRequest.newBuilder());
    }

    FetchColorLibraryResponse fetch(String user, UUID doc, long knownSeq) {
        return by(user).fetchColorLibrary(FetchColorLibraryRequest.newBuilder().setDocumentId(doc.toString())
                .setKnownSeq(knownSeq).build());
    }

    List<ColorLibraryInfo> list(String user, UUID team, int pageSize) {
        List<ColorLibraryInfo> all = new ArrayList<>();
        ListColorLibrariesRequest.Builder request = ListColorLibrariesRequest.newBuilder().setTeamId(team.toString())
                .setPageSize(pageSize);
        ListColorLibrariesResponse page;
        do {
            page = by(user).listColorLibraries(request.build());
            all.addAll(page.getLibrariesList());
            request.setCursor(page.getNextCursor());
        } while (!page.getNextCursor().isEmpty());
        return all;
    }

    void unpublish(String user, UUID doc) {
        by(user).unpublishColorLibrary(UnpublishColorLibraryRequest.newBuilder().setDocumentId(doc.toString()).build());
    }

    long changes(UUID doc) {
        return count("SELECT count(*) FROM change_log WHERE document_id = ?", doc);
    }

    @Test
    void membersListAndFetchAnAutomaticLibraryThatFollowsTheHead() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        teamMember(team, carol, "guest");
        UUID doc = teamDocument(team, "Brand colors");
        Author author = new Author(replicaId());
        OpId grape = author.next();
        long seq = push(ALICE, null, doc, author.change("grape", color("Grape", rgb(0.4, 0.1, 0.6), false, "Fruit")),
                author.change("pms", color("PANTONE 300 C", cmyk(1, 0.44, 0, 0), true, "")));

        assertFails(() -> publish(BOB, doc), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        ColorLibraryInfo published = publish(ALICE, doc);
        assertThat(published.getName()).isEqualTo("Brand colors");
        assertThat(published.getTeamId()).isEqualTo(team.toString());
        assertThat(published.getMode()).isEqualTo(ColorLibraryMode.COLOR_LIBRARY_MODE_AUTOMATIC);
        assertThat(published.getPublishedSeq()).isEqualTo(seq);
        assertThat(published.getPublishedByAccountId()).isEqualTo(alice.toString());
        assertThat(published.getUpdatedMs()).isPositive();

        assertThat(list(BOB, team, 0)).containsExactly(published);
        FetchColorLibraryResponse fetched = fetch(BOB, doc, 0);
        assertThat(fetched.getLibrary()).isEqualTo(published);
        assertThat(fetched.getColors().getName()).isEqualTo("Brand colors");
        assertThat(fetched.getColors().getColorsList()).extracting(LibraryColor::getName)
                .containsExactly("Grape", "PANTONE 300 C");
        assertThat(fetched.getColors().getColors(0).getKey())
                .isEqualTo(grape.getCounter() + ":" + Long.toUnsignedString(grape.getReplica()));
        // The cached version: no colors.
        assertThat(fetch(BOB, doc, seq).hasColors()).isFalse();

        // Every change is the new version.
        long next = push(ALICE, null, doc, author.change("recolor", recolor(grape, rgb(0.5, 0.1, 0.6))));
        FetchColorLibraryResponse updated = fetch(BOB, doc, seq);
        assertThat(updated.getLibrary().getPublishedSeq()).isEqualTo(next);
        assertThat(updated.getLibrary().getUpdatedMs()).isGreaterThanOrEqualTo(published.getUpdatedMs());
        assertThat(updated.getColors().getColors(0).getValue()).isEqualTo(rgb(0.5, 0.1, 0.6));

        // A guest and an outsider cannot use it; the outsider does not learn it exists.
        assertFails(() -> list(CAROL, team, 0), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> fetch(CAROL, doc, 0), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> list(DAVE, team, 0), Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        assertFails(() -> fetch(DAVE, doc, 0), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        assertFails(() -> fetch(BOB, uuid7(), 0), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
    }

    @Test
    void aManualLibraryKeepsItsPublishedVersion() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        UUID doc = teamDocument(team, "Print colors");
        Author author = new Author(replicaId());
        OpId red = author.next();
        long first = push(ALICE, null, doc, author.change("red", color("Red", rgb(1, 0, 0), false, "")));
        long second = push(ALICE, null, doc, author.change("recolor", recolor(red, rgb(0.9, 0, 0))));

        ColorLibraryInfo manual = publish(ALICE, doc, PublishColorLibraryRequest.newBuilder().setName("Print")
                .setMode(ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL).setServerSeq(first));
        assertThat(manual.getMode()).isEqualTo(ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL);
        assertThat(manual.getPublishedSeq()).isEqualTo(first);
        push(ALICE, null, doc, author.change("again", recolor(red, rgb(0.8, 0, 0))));
        FetchColorLibraryResponse fetched = fetch(BOB, doc, 0);
        assertThat(fetched.getLibrary().getPublishedSeq()).isEqualTo(first);
        assertThat(fetched.getColors().getName()).isEqualTo("Print");
        assertThat(fetched.getColors().getColors(0).getValue()).isEqualTo(rgb(1, 0, 0));

        // A version past the head is refused and changes nothing.
        assertFails(() -> publish(ALICE, doc, PublishColorLibraryRequest.newBuilder().setServerSeq(99)),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertThat(fetch(BOB, doc, 0).getLibrary().getPublishedSeq()).isEqualTo(first);

        // Publishing again keeps the mode and name, and publishes the head (Publish Library Version).
        ColorLibraryInfo head = publish(ALICE, doc, PublishColorLibraryRequest.newBuilder());
        assertThat(head.getMode()).isEqualTo(ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL);
        assertThat(head.getName()).isEqualTo("Print");
        assertThat(head.getPublishedSeq()).isEqualTo(second + 1);
        // A rename answers the stored colors under the new name.
        publish(ALICE, doc, PublishColorLibraryRequest.newBuilder().setName("Press").setServerSeq(second));
        FetchColorLibraryResponse renamed = fetch(BOB, doc, 0);
        assertThat(renamed.getColors().getName()).isEqualTo("Press");
        assertThat(renamed.getColors().getColors(0).getValue()).isEqualTo(rgb(0.9, 0, 0));

        // Back to automatic: the head again.
        ColorLibraryInfo automatic = publish(ALICE, doc, PublishColorLibraryRequest.newBuilder()
                .setMode(ColorLibraryMode.COLOR_LIBRARY_MODE_AUTOMATIC));
        assertThat(automatic.getPublishedSeq()).isEqualTo(second + 1);
        assertThat(fetch(BOB, doc, 0).getColors().getColors(0).getValue()).isEqualTo(rgb(0.8, 0, 0));
        assertThat(value("SELECT colors FROM color_library WHERE document_id = ?", doc)).isNull();

        // A stored version that no longer parses is a server fault, not a wrong answer.
        publish(ALICE, doc, PublishColorLibraryRequest.newBuilder().setMode(ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL));
        exec("UPDATE color_library SET colors = ? WHERE document_id = ?", new byte[] {(byte) 0xff, (byte) 0xff}, doc);
        StatusRuntimeException corrupt = failure(() -> fetch(BOB, doc, 0));
        assertThat(corrupt.getStatus().getCode()).isNotEqualTo(Status.Code.OK);
    }

    @Test
    void personalDocumentsArePublishedToATeamTheirOwnerBelongsTo() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        UUID elsewhere = team(dave, "viewer");
        UUID personal = document(ALICE);
        push(ALICE, null, personal, new Author(replicaId()).change("red", color("Red", rgb(1, 0, 0), false, "")));

        assertFails(() -> publish(ALICE, personal), Status.Code.FAILED_PRECONDITION, ErrorReasons.TEAM_ROLE_INVALID);
        assertFails(() -> publish(ALICE, personal, PublishColorLibraryRequest.newBuilder().setTeamId(elsewhere.toString())),
                Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        ColorLibraryInfo published = publish(ALICE, personal,
                PublishColorLibraryRequest.newBuilder().setTeamId(team.toString()).setName("Mine"));
        assertThat(published.getTeamId()).isEqualTo(team.toString());
        // Bob uses it without any role on the document itself.
        assertThat(fetch(BOB, personal, 0).getColors().getColorsCount()).isEqualTo(1);
        assertFails(() -> blocking(BOB, null).fetchChanges(FetchChangesRequest.newBuilder()
                .setDocumentId(personal.toString()).build()).next(), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);

        // A team document goes to its own team only.
        UUID teamDoc = teamDocument(team, "Team doc");
        assertFails(() -> publish(ALICE, teamDoc, PublishColorLibraryRequest.newBuilder().setTeamId(elsewhere.toString())),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.TEAM_ROLE_INVALID);
        // An empty document is a library with no colors, dated by its publishing.
        ColorLibraryInfo empty = publish(ALICE, teamDoc, PublishColorLibraryRequest.newBuilder().setTeamId(team.toString()));
        assertThat(empty.getPublishedSeq()).isZero();
        assertThat(fetch(BOB, teamDoc, 0).getColors().getColorsCount()).isZero();
        assertThat(list(BOB, team, 1)).extracting(ColorLibraryInfo::getName).containsExactly("Mine", "Team doc");
    }

    @Test
    void unpublishingAndTrashingLeaveTheDocumentUntouched() {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        UUID doc = teamDocument(team, "Brand");
        push(ALICE, null, doc, new Author(replicaId()).change("red", color("Red", rgb(1, 0, 0), false, "")));
        publish(ALICE, doc);
        long logged = changes(doc);

        assertFails(() -> unpublish(BOB, doc), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        unpublish(ALICE, doc);
        unpublish(ALICE, doc);
        assertThat(list(BOB, team, 0)).isEmpty();
        assertFails(() -> fetch(BOB, doc, 0), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        assertThat(changes(doc)).isEqualTo(logged);
        assertThat(value("SELECT trashed_at FROM document WHERE id = ?", doc)).isNull();

        // Trashing the library document unpublishes it for its consumers; restoring brings it back.
        publish(ALICE, doc);
        TestUsers.as(docs, ALICE).trash(TrashRequest.newBuilder().setDocumentId(doc.toString()).build());
        assertThat(list(BOB, team, 0)).isEmpty();
        assertFails(() -> fetch(BOB, doc, 0), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        assertFails(() -> publish(ALICE, doc), Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        TestUsers.as(docs, ALICE).restore(RestoreRequest.newBuilder().setDocumentId(doc.toString()).build());
        assertThat(list(BOB, team, 0)).extracting(ColorLibraryInfo::getName).containsExactly("Brand");
        // Deleting it for good deletes the library.
        exec("DELETE FROM document WHERE id = ?", doc);
        assertThat(count("SELECT count(*) FROM color_library WHERE document_id = ?", doc)).isZero();
        assertThat(list(BOB, team, 0)).isEmpty();
    }

    /** A team library of {@code swatches} colors pushed in changes of 500; returns the document. */
    UUID bigLibrary(int swatches) {
        UUID team = team(alice, "viewer");
        teamMember(team, bob, "member");
        UUID doc = teamDocument(team, "Big");
        Author author = new Author(replicaId());
        List<Change> changes = new ArrayList<>();
        for (int from = 0; from < swatches; from += 500) {
            List<Op> ops = new ArrayList<>();
            for (int i = from; i < Math.min(swatches, from + 500); i++) {
                ops.add(color("Color " + i, rgb(i / (double) swatches, 0.5, 0.25), i % 7 == 0, "Group " + i / 100));
            }
            changes.add(author.change("colors", ops));
        }
        pushAll(ALICE, null, doc, changes);
        publish(ALICE, doc);
        return doc;
    }

    @Test
    void aFiveThousandSwatchLibraryFetchesWhole() {
        UUID doc = bigLibrary(5000);
        FetchColorLibraryResponse fetched = fetch(BOB, doc, 0);
        assertThat(fetched.getColors().getColorsCount()).isEqualTo(5000);
        assertThat(fetched.getColors().getColors(4999).getName()).isEqualTo("Color 4999");
        assertThat(DocOps.SWATCHES).isEqualTo(5);
    }

    @PerfTest
    void aFiveThousandSwatchFetchIsUnder200Ms() {
        UUID doc = bigLibrary(5000);
        fetch(BOB, doc, 0);
        long started = System.nanoTime();
        FetchColorLibraryResponse fetched = fetch(BOB, doc, 0);
        long elapsed = System.nanoTime() - started;
        assertThat(fetched.getColors().getColorsCount()).isEqualTo(5000);
        PerfReport.measured("FetchColorLibrary, 5,000 swatches (COLOR-020)",
                String.format(Locale.ROOT, "%.0f ms", elapsed / 1e6), "< 200 ms",
                elapsed < TimeUnit.MILLISECONDS.toNanos(200));
        assertThat(elapsed).isLessThan(TimeUnit.MILLISECONDS.toNanos(200));
    }
}
