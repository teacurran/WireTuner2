package com.villagecompute.wiretuner.api.font;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.villagecompute.wiretuner.account.v1.FetchFontRequest;
import com.villagecompute.wiretuner.account.v1.FetchFontResponse;
import com.villagecompute.wiretuner.account.v1.FontFace;
import com.villagecompute.wiretuner.account.v1.FontLibraryServiceGrpc;
import com.villagecompute.wiretuner.account.v1.ListFontsRequest;
import com.villagecompute.wiretuner.account.v1.ListFontsResponse;
import com.villagecompute.wiretuner.account.v1.MutinyFontLibraryServiceGrpc;
import com.villagecompute.wiretuner.account.v1.RemoveFontRequest;
import com.villagecompute.wiretuner.account.v1.TeamFont;
import com.villagecompute.wiretuner.account.v1.UploadFontHeader;
import com.villagecompute.wiretuner.account.v1.UploadFontRequest;
import com.villagecompute.wiretuner.account.v1.UploadFontResponse;
import com.villagecompute.wiretuner.api.PerfReport;
import com.villagecompute.wiretuner.api.PerfTest;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.blob.Upload;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.history.HistoryTestSupport;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.grpc.GrpcClient;
import io.quarkus.test.junit.QuarkusTest;
import io.smallrye.mutiny.Multi;

/**
 * TXT-002's server half end to end: admins upload licensed fonts to a team's library (verified,
 * read, licence-checked, stored once as a blob, counted against the team's quota); members above
 * guest list the catalog with a version to cache by and fetch the files; guests are refused and
 * outsiders see no team; removal hides a font at once and the Trash job deletes it 30 days later.
 */
@QuarkusTest
class FontLibraryServiceTest extends HistoryTestSupport {

    static final Duration WAIT = Duration.ofMinutes(2);
    static final int MIB = 1024 * 1024;

    @GrpcClient("fonts")
    FontLibraryServiceGrpc.FontLibraryServiceBlockingStub fonts;

    @GrpcClient("fonts")
    MutinyFontLibraryServiceGrpc.MutinyFontLibraryServiceStub streams;

    UUID dave;
    UUID erin;
    UUID team;

    @BeforeEach
    void more() {
        dave = TestUsers.accountId(account, DAVE);
        erin = TestUsers.accountId(account, ERIN);
        team = team(alice, "viewer");
        teamMember(team, bob, "member");
        teamMember(team, carol, "guest");
        teamMember(team, erin, "admin");
    }

    static ByteString sha(byte[] bytes) {
        return ByteString.copyFrom(Upload.digest("SHA-256").digest(bytes));
    }

    static String hex(byte[] bytes) {
        return FontLibraryGrpcService.hex(sha(bytes));
    }

    static UploadFontHeader header(UUID team, byte[] file, String name) {
        return UploadFontHeader.newBuilder().setTeamId(team.toString()).setSha256(sha(file)).setSize(file.length)
                .setFileName(name).build();
    }

    static Multi<UploadFontRequest> frames(UploadFontHeader header, byte[] file) {
        List<UploadFontRequest> frames = new ArrayList<>();
        frames.add(UploadFontRequest.newBuilder().setHeader(header).build());
        for (int at = 0; at < file.length; at += MIB) {
            frames.add(UploadFontRequest.newBuilder()
                    .setChunk(ByteString.copyFrom(file, at, Math.min(MIB, file.length - at))).build());
        }
        return Multi.createFrom().iterable(frames);
    }

    UploadFontResponse upload(String user, UploadFontHeader header, byte[] file) {
        return TestUsers.as(streams, user).uploadFont(frames(header, file)).await().atMost(WAIT);
    }

    UploadFontResponse upload(String user, UUID team, byte[] file, String name) {
        return upload(user, header(team, file, name), file);
    }

    List<FetchFontResponse> fetch(String user, UUID team, byte[] file) {
        return TestUsers.as(streams, user).fetchFont(FetchFontRequest.newBuilder().setTeamId(team.toString())
                .setSha256(sha(file)).build()).collect().asList().await().atMost(WAIT);
    }

    static byte[] joined(List<FetchFontResponse> frames) {
        ByteString all = ByteString.EMPTY;
        for (FetchFontResponse frame : frames.subList(1, frames.size())) {
            assertThat(frame.getChunk().size()).isLessThanOrEqualTo(MIB);
            all = all.concat(frame.getChunk());
        }
        return all.toByteArray();
    }

    ListFontsResponse page(String user, UUID team, String cursor, int pageSize, long known) {
        return TestUsers.as(fonts, user).listFonts(ListFontsRequest.newBuilder().setTeamId(team.toString())
                .setCursor(cursor).setPageSize(pageSize).setKnownVersion(known).build());
    }

    List<TeamFont> list(String user, UUID team) {
        List<TeamFont> all = new ArrayList<>();
        String cursor = "";
        do {
            ListFontsResponse page = page(user, team, cursor, 2, 0);
            all.addAll(page.getFontsList());
            cursor = page.getNextCursor();
        } while (!cursor.isEmpty());
        return all;
    }

    long remove(String user, UUID team, byte[] file) {
        return TestUsers.as(fonts, user).removeFont(RemoveFontRequest.newBuilder().setTeamId(team.toString())
                .setSha256(sha(file)).build()).getVersion();
    }

    @Test
    void adminsUploadAndMembersListAndFetch() {
        byte[] inter = TestFonts.ttf("Inter", "Bold", 0x0008);
        UploadFontResponse uploaded = upload(ERIN, team, inter, "Inter-Bold.ttf");
        TeamFont font = uploaded.getFont();
        assertThat(uploaded.getVersion()).isEqualTo(1);
        assertThat(font.getSha256()).isEqualTo(sha(inter));
        assertThat(font.getTeamId()).isEqualTo(team.toString());
        assertThat(font.getFileName()).isEqualTo("Inter-Bold.ttf");
        assertThat(font.getSize()).isEqualTo(inter.length);
        assertThat(font.getMediaType()).isEqualTo("font/ttf");
        assertThat(font.getUploadedByAccountId()).isEqualTo(erin.toString());
        assertThat(font.getUploadedMs()).isPositive();
        assertThat(font.getFacesList()).containsExactly(FontFace.newBuilder().setFamily("Inter").setStyle("Bold")
                .setPostscriptName("Inter-Bold").setFsType(8).build());
        // The file is a blob like any other.
        assertThat(value("SELECT media_type FROM blob WHERE sha256 = ?", hex(inter))).isEqualTo("font/ttf");
        assertThat(stored(BlobStore.key(hex(inter)))).isTrue();

        // Uploading it again changes nothing.
        UploadFontResponse again = upload(ALICE, team, inter, "renamed.ttf");
        assertThat(again.getVersion()).isEqualTo(1);
        assertThat(again.getFont()).isEqualTo(font);

        assertThat(list(BOB, team)).containsExactly(font);
        List<FetchFontResponse> frames = fetch(BOB, team, inter);
        assertThat(frames.get(0).getFont()).isEqualTo(font);
        assertThat(joined(frames)).isEqualTo(inter);

        // The cached catalog: unchanged, and no fonts; an older one gets the catalog.
        ListFontsResponse unchanged = page(BOB, team, "", 0, 1);
        assertThat(unchanged.getUnchanged()).isTrue();
        assertThat(unchanged.getVersion()).isEqualTo(1);
        assertThat(unchanged.getFontsList()).isEmpty();
        ListFontsResponse stale = page(BOB, team, "", 0, 7);
        assertThat(stale.getUnchanged()).isFalse();
        assertThat(stale.getFontsList()).containsExactly(font);
    }

    @Test
    void guestsAreRefusedAndOutsidersSeeNoTeam() {
        byte[] file = TestFonts.ttf("Guarded", "Regular", 0);
        upload(ALICE, team, file, "g.ttf");

        assertFails(() -> upload(BOB, team, file, "g.ttf"), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> remove(BOB, team, file), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> list(CAROL, team), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> fetch(CAROL, team, file), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> upload(DAVE, team, file, "g.ttf"), Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        assertFails(() -> remove(DAVE, team, file), Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        assertFails(() -> list(DAVE, team), Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        assertFails(() -> fetch(DAVE, team, file), Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        // A font the library does not hold.
        assertFails(() -> fetch(BOB, team, TestFonts.ttf("Elsewhere", "Regular", 0)), Status.Code.NOT_FOUND,
                ErrorReasons.BLOB_NOT_FOUND);
        // Nor does another team's library.
        UUID other = team(dave, "viewer");
        assertFails(() -> fetch(DAVE, other, file), Status.Code.NOT_FOUND, ErrorReasons.BLOB_NOT_FOUND);
        assertThat(list(DAVE, other)).isEmpty();
    }

    @Test
    void theCatalogPagesByFamilyUnderOneVersion() {
        byte[] c = TestFonts.ttf("Charter", "Roman", 0);
        byte[] a = TestFonts.ttf("Avenir", "Book", 0);
        byte[] b = TestFonts.collection(java.util.Map.entry(FontFiles.SFNT_1, TestFonts.tables("Baskerville", "Regular", 0)),
                java.util.Map.entry(FontFiles.SFNT_1, TestFonts.tables("Baskerville", "Italic", 0)));
        upload(ALICE, team, c, "charter.ttf");
        upload(ALICE, team, a, "avenir.ttf");
        long version = upload(ALICE, team, b, "baskerville.ttc").getVersion();
        assertThat(version).isEqualTo(3);

        ListFontsResponse first = page(BOB, team, "", 2, 0);
        assertThat(first.getFontsList()).extracting(TeamFont::getFileName).containsExactly("avenir.ttf", "baskerville.ttc");
        assertThat(first.getFonts(1).getMediaType()).isEqualTo("font/collection");
        assertThat(first.getFonts(1).getFacesList()).extracting(FontFace::getStyle).containsExactly("Regular", "Italic");
        // A cursor ignores known_version: the page after it is always answered.
        ListFontsResponse second = page(BOB, team, first.getNextCursor(), 2, version);
        assertThat(second.getUnchanged()).isFalse();
        assertThat(second.getFontsList()).extracting(TeamFont::getFileName).containsExactly("charter.ttf");
        assertThat(second.getNextCursor()).isEmpty();
        assertThat(second.getVersion()).isEqualTo(version);

        assertFails(() -> page(BOB, team, "not a cursor", 2, 0), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
    }

    @Test
    void removedFontsAreHiddenThenPurgedUnlessUploadedAgain() {
        byte[] file = TestFonts.ttf("Futura", "Medium", 0);
        upload(ERIN, team, file, "futura.ttf");
        assertThat(remove(ERIN, team, file)).isEqualTo(2);
        assertThat(list(BOB, team)).isEmpty();
        assertFails(() -> fetch(BOB, team, file), Status.Code.NOT_FOUND, ErrorReasons.BLOB_NOT_FOUND);
        // Removing it again, or a font never uploaded, changes nothing.
        assertThat(remove(ERIN, team, file)).isEqualTo(2);
        assertThat(remove(ALICE, team, TestFonts.ttf("Never", "Regular", 0))).isEqualTo(2);

        // Uploading it again brings it back under the new upload's name and uploader.
        UploadFontResponse back = upload(ALICE, team, file, "Futura Medium.ttf");
        assertThat(back.getVersion()).isEqualTo(3);
        assertThat(back.getFont().getFileName()).isEqualTo("Futura Medium.ttf");
        assertThat(back.getFont().getUploadedByAccountId()).isEqualTo(alice.toString());
        assertThat(joined(fetch(BOB, team, file))).isEqualTo(file);

        // Removed 31 days ago: the Trash job deletes the row, then the blob once nothing else holds it.
        remove(ALICE, team, file);
        exec("UPDATE team_font SET removed_at = now() - interval '31 days' WHERE team_id = ?", team);
        exec("UPDATE blob SET created_at = now() - interval '2 days' WHERE sha256 = ?", hex(file));
        runTrash();
        assertThat(count("SELECT count(*) FROM team_font WHERE team_id = ?", team)).isZero();
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 = ?", hex(file))).isZero();
        assertThat(stored(BlobStore.key(hex(file)))).isFalse();
    }

    @Test
    void aFontSharedByTwoTeamsIsStoredOnceAndKeptWhileEitherHoldsIt() {
        byte[] file = TestFonts.ttf("Shared", "Regular", 0);
        UUID other = team(alice, "viewer");
        upload(ALICE, team, file, "shared.ttf");
        upload(ALICE, other, file, "shared.ttf");
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 = ?", hex(file))).isEqualTo(1);
        assertThat(count("SELECT count(*) FROM team_font WHERE sha256 = ?", hex(file))).isEqualTo(2);

        remove(ALICE, team, file);
        exec("UPDATE team_font SET removed_at = now() - interval '31 days' WHERE team_id = ?", team);
        exec("UPDATE blob SET created_at = now() - interval '2 days' WHERE sha256 = ?", hex(file));
        runTrash();
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 = ?", hex(file))).isEqualTo(1);
        assertThat(joined(fetch(ALICE, other, file))).isEqualTo(file);
    }

    @Test
    void aLargeFontTravelsInFrames() {
        byte[] file = TestFonts.ttf("Noto Sans CJK", 3 * MIB + 17);
        upload(ALICE, team, file, "NotoSansCJK.ttc");
        List<FetchFontResponse> frames = fetch(BOB, team, file);
        assertThat(frames).hasSizeGreaterThan(4);
        assertThat(joined(frames)).isEqualTo(file);
    }

    @Test
    void filesThatAreNotLicensedFontsAreRefusedAndNeverStored() {
        byte[] restricted = TestFonts.ttf("Restricted", "Regular", 0x0002);
        StatusRuntimeException refused = failure(() -> upload(ALICE, team, restricted, "r.ttf"));
        assertThat(refused.getStatus().getCode()).isEqualTo(Status.Code.INVALID_ARGUMENT);
        assertThat(refused.getStatus().getDescription()).contains("not a font the team library accepts");
        assertFails(() -> upload(ALICE, team, restricted, "r.ttf"), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
        byte[] text = "just some text, not a font".getBytes();
        assertFails(() -> upload(ALICE, team, text, "notes.ttf"), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 IN (?, ?)", hex(restricted), hex(text))).isZero();
        assertThat(count("SELECT count(*) FROM team_font WHERE team_id = ?", team)).isZero();
        assertThat(value("SELECT font_library_version FROM team WHERE id = ?", team)).isEqualTo(0L);
    }

    @Test
    void contentThatDisagreesWithTheHeaderIsRejected() {
        byte[] file = TestFonts.ttf("Mismatch", "Regular", 0);
        byte[] other = TestFonts.ttf("Other", "Regular", 0);
        UploadFontHeader header = header(team, file, "m.ttf");
        assertFails(() -> upload(ALICE, header.toBuilder().setSha256(sha(other)).build(), file),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.BLOB_MISMATCH);
        assertFails(() -> upload(ALICE, header.toBuilder().setSize(file.length + 1).build(), file),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.BLOB_MISMATCH);
        assertFails(() -> upload(ALICE, header.toBuilder().setSize(file.length - 1).build(), file),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.BLOB_MISMATCH);

        UploadFontRequest head = UploadFontRequest.newBuilder().setHeader(header).build();
        UploadFontRequest chunk = UploadFontRequest.newBuilder().setChunk(ByteString.copyFrom(file)).build();
        assertFails(() -> TestUsers.as(streams, ALICE).uploadFont(Multi.createFrom().items(chunk, head)).await().atMost(WAIT),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.BLOB_MISMATCH);
        assertFails(() -> TestUsers.as(streams, ALICE).uploadFont(Multi.createFrom().items(head, head, chunk)).await()
                .atMost(WAIT), Status.Code.INVALID_ARGUMENT, ErrorReasons.BLOB_MISMATCH);
        assertFails(() -> TestUsers.as(streams, ALICE).uploadFont(Multi.createFrom().empty()).await().atMost(WAIT),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.BLOB_MISMATCH);
        // Over the 64 MiB cap: refused by the header's validation.
        assertFails(() -> upload(ALICE, header.toBuilder().setSize(64L * MIB + 1).build(), file),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertThat(count("SELECT count(*) FROM blob WHERE sha256 = ?", hex(file))).isZero();
    }

    @Test
    void fontsCountTowardsTheTeamsStorageQuota() {
        byte[] small = TestFonts.ttf("Small", "Regular", 0);
        upload(ALICE, team, small, "small.ttf");
        exec("UPDATE team SET storage_limit_bytes = ? WHERE id = ?", (long) small.length + 10, team);
        byte[] big = TestFonts.ttf("Big", 4096);
        assertFails(() -> upload(ALICE, team, big, "big.ttf"), Status.Code.RESOURCE_EXHAUSTED, ErrorReasons.STORAGE_QUOTA);
        // A font the team already holds is always accepted, removed or not.
        remove(ALICE, team, small);
        assertThat(upload(ALICE, team, small, "small.ttf").getVersion()).isEqualTo(3);
    }

    @Test
    void aGoneUploaderAndACorruptRowAreHandled() {
        byte[] file = TestFonts.ttf("Orphaned", "Regular", 0);
        upload(ERIN, team, file, "o.ttf");
        exec("UPDATE team_font SET uploaded_by = NULL WHERE team_id = ?", team);
        assertThat(list(BOB, team).get(0).getUploadedByAccountId()).isEmpty();
        exec("UPDATE team_font SET faces = ? WHERE team_id = ?", new byte[] {(byte) 0xff, (byte) 0xff}, team);
        StatusRuntimeException corrupt = failure(() -> list(BOB, team));
        assertThat(corrupt.getStatus().getCode()).isNotEqualTo(Status.Code.OK);
    }

    @PerfTest
    void fetchingA16MibFontIsUnder1s() {
        byte[] file = TestFonts.ttf("Perf Sans", 16 * MIB);
        upload(ALICE, team, file, "perf.ttf");
        fetch(BOB, team, file);
        long started = System.nanoTime();
        List<FetchFontResponse> frames = fetch(BOB, team, file);
        long elapsed = System.nanoTime() - started;
        assertThat(joined(frames)).hasSize(file.length);
        PerfReport.measured("FetchFont, 16 MiB (TXT-002)", String.format(Locale.ROOT, "%.0f ms", elapsed / 1e6), "< 1 s",
                elapsed < TimeUnit.SECONDS.toNanos(1));
        assertThat(elapsed).isLessThan(TimeUnit.SECONDS.toNanos(1));
    }

    @PerfTest
    void uploadingA16MibFontIsUnder2s() {
        byte[] file = TestFonts.ttf("Perf Serif", 16 * MIB);
        upload(ALICE, team, TestFonts.ttf("Warm", "Regular", 0), "warm.ttf");
        long started = System.nanoTime();
        upload(ALICE, team, file, "perf.ttf");
        long elapsed = System.nanoTime() - started;
        PerfReport.measured("UploadFont, 16 MiB (TXT-002)", String.format(Locale.ROOT, "%.0f ms", elapsed / 1e6), "< 2 s",
                elapsed < TimeUnit.SECONDS.toNanos(2));
        assertThat(elapsed).isLessThan(TimeUnit.SECONDS.toNanos(2));
    }
}
