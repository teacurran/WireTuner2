package com.villagecompute.wiretuner.api.font;

import java.util.HexFormat;
import java.util.UUID;
import java.util.function.Supplier;

import com.google.protobuf.ByteString;
import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.account.v1.FetchFontRequest;
import com.villagecompute.wiretuner.account.v1.FetchFontResponse;
import com.villagecompute.wiretuner.account.v1.ListFontsRequest;
import com.villagecompute.wiretuner.account.v1.ListFontsResponse;
import com.villagecompute.wiretuner.account.v1.MutinyFontLibraryServiceGrpc;
import com.villagecompute.wiretuner.account.v1.RemoveFontRequest;
import com.villagecompute.wiretuner.account.v1.RemoveFontResponse;
import com.villagecompute.wiretuner.account.v1.TeamFont;
import com.villagecompute.wiretuner.account.v1.UploadFontHeader;
import com.villagecompute.wiretuner.account.v1.UploadFontRequest;
import com.villagecompute.wiretuner.account.v1.UploadFontResponse;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.blob.BlobGrpcService.Rechunker;
import com.villagecompute.wiretuner.api.blob.BlobStore;
import com.villagecompute.wiretuner.api.blob.StorageQuota;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.library.TeamMembership;
import com.villagecompute.wiretuner.api.persistence.BlobRepository;
import com.villagecompute.wiretuner.api.persistence.TeamFontRepository;
import com.villagecompute.wiretuner.api.persistence.TeamFontRepository.Font;
import com.villagecompute.wiretuner.api.team.TeamRoles;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.account.v1.FontLibraryService} (TXT-002's server half; font-substitution.adoc,
 * Server). A team's font library is its {@code team_font} rows, each a content-addressed blob in the
 * {@code blob} table and object storage, as {@code BlobService} keeps them, referenced by the team
 * instead of a document. Uploading and removing need the team's admin role (as D-062 has it for
 * credentials); listing and fetching need membership above guest; to an outsider the team is absent.
 *
 * <p>An upload is held in memory (at most 64 MiB) and read whole before anything is stored: the size
 * and sha256 must match the header ({@code BLOB_MISMATCH}), and {@link FontFiles} must accept the file
 * -- a font with outlines whose every face's {@code OS/2.fsType} allows document embedding
 * ({@code VALIDATION_FAILED} otherwise). The file counts towards the team's storage quota, checked at
 * the header. Every upload that changes the library and every removal moves the team's catalog
 * version, which {@code ListFonts.known_version} compares with. Removing hides the font at once; the
 * Trash job deletes the row 30 days later and the blob with the orphans.
 */
@GrpcService
public class FontLibraryGrpcService extends MutinyFontLibraryServiceGrpc.FontLibraryServiceImplBase {

    /** Fetch frames are at most this long (the proto's 1 MiB cap). */
    static final int CHUNK = 1024 * 1024;

    @Inject
    RoleGuard guard;

    @Inject
    TeamMembership membership;

    @Inject
    TeamFontRepository fonts;

    @Inject
    BlobRepository blobs;

    @Inject
    BlobStore store;

    @Inject
    StorageQuota quota;

    @Override
    public Uni<UploadFontResponse> uploadFont(Multi<UploadFontRequest> frames) {
        FontUpload upload = new FontUpload();
        return frames.onItem().transformToUniAndConcatenate(frame -> accept(upload, frame))
                .collect().last()
                .chain(upload::finish)
                .call(font -> upload.alreadyStored ? Uni.createFrom().voidItem()
                        : store.put(BlobStore.key(upload.sha256Hex()), upload.bytes(), font.mediaType()))
                .chain(font -> tx(() -> record(upload, font)));
    }

    private Uni<Void> accept(FontUpload upload, UploadFontRequest frame) {
        if (upload.header != null) {
            return upload.chunk(frame);
        }
        if (!frame.hasHeader()) {
            return Uni.createFrom().failure(StatusExceptions.blobMismatch("the first frame of an upload must be its header"));
        }
        UploadFontHeader header = frame.getHeader();
        UUID teamId = UUID.fromString(header.getTeamId());
        String sha = hex(header.getSha256());
        return tx(() -> guard.authenticated()
                .call(principal -> membership.require(principal, teamId, TeamRoles.ADMIN))
                .flatMap(principal -> blobs.findById(sha).invoke(existing -> upload.begin(header, principal.accountId(),
                        existing != null))))
                .call(() -> quota.admitSpace(teamId, sha, header.getSize()))
                .replaceWithVoid();
    }

    /** Records the blob row (first upload wins), then the team's font, moving the version when the library changed. */
    private Uni<UploadFontResponse> record(FontUpload upload, FontFiles.Font font) {
        UUID teamId = upload.teamId();
        String sha = upload.sha256Hex();
        byte[] faces = TeamFont.newBuilder().addAllFaces(font.faces()).build().toByteArray();
        return blobs.insertIfAbsent(sha, upload.header.getSize(), font.mediaType(), BlobStore.key(sha), "content")
                .chain(() -> fonts.add(teamId, sha, upload.header.getFileName(), font.mediaType(),
                        font.faces().get(0).getFamily(), faces, upload.accountId))
                .call(changed -> changed ? fonts.bump(teamId) : Uni.createFrom().voidItem())
                .chain(() -> fonts.live(teamId, sha))
                .chain(row -> fonts.version(teamId).map(version -> UploadFontResponse.newBuilder()
                        .setFont(info(row)).setVersion(version).build()));
    }

    @Override
    public Uni<ListFontsResponse> listFonts(ListFontsRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        boolean first = request.getCursor().isEmpty();
        int offset = first ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> guard.authenticated().flatMap(principal -> membership.require(principal, teamId))
                .chain(() -> fonts.version(teamId))
                .chain(version -> {
                    ListFontsResponse.Builder response = ListFontsResponse.newBuilder().setVersion(version);
                    if (first && request.getKnownVersion() != 0 && request.getKnownVersion() == version) {
                        return Uni.createFrom().item(response.setUnchanged(true).build());
                    }
                    return fonts.page(teamId, offset, pageSize + 1).map(rows -> {
                        if (rows.size() > pageSize) {
                            response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                        }
                        rows.subList(0, Math.min(rows.size(), pageSize)).forEach(row -> response.addFonts(info(row)));
                        return response.build();
                    });
                }));
    }

    @Override
    public Multi<FetchFontResponse> fetchFont(FetchFontRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        String sha = hex(request.getSha256());
        return tx(() -> guard.authenticated().flatMap(principal -> membership.require(principal, teamId))
                .chain(() -> fonts.live(teamId, sha))
                .onItem().ifNull().failWith(StatusExceptions::blobNotFound))
                .onItem().transformToMulti(row -> {
                    Rechunker rechunker = new Rechunker(CHUNK);
                    Multi<FetchFontResponse> chunks = store.get(row.storageKey())
                            .onItem().transformToIterable(rechunker::add)
                            .onCompletion().switchTo(() -> Multi.createFrom().iterable(rechunker.flush()))
                            .map(chunk -> FetchFontResponse.newBuilder().setChunk(chunk).build());
                    return Multi.createBy().concatenating().streams(
                            Multi.createFrom().item(FetchFontResponse.newBuilder().setFont(info(row)).build()), chunks);
                });
    }

    @Override
    public Uni<RemoveFontResponse> removeFont(RemoveFontRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        String sha = hex(request.getSha256());
        return tx(() -> guard.authenticated()
                .flatMap(principal -> membership.require(principal, teamId, TeamRoles.ADMIN))
                .chain(() -> fonts.remove(teamId, sha))
                .call(removed -> removed ? fonts.bump(teamId) : Uni.createFrom().voidItem())
                .chain(() -> fonts.version(teamId)))
                .map(version -> RemoveFontResponse.newBuilder().setVersion(version).build());
    }

    /** The catalog entry of a stored font. */
    static TeamFont info(Font row) {
        return decode(row.faces()).toBuilder()
                .setSha256(ByteString.copyFrom(HexFormat.of().parseHex(row.sha256())))
                .setTeamId(row.teamId().toString())
                .setFileName(row.fileName())
                .setSize(row.size())
                .setMediaType(row.mediaType())
                .setUploadedByAccountId(row.uploadedBy() == null ? "" : row.uploadedBy().toString())
                .setUploadedMs(row.uploadedMillis())
                .build();
    }

    /** Stored faces; they were written by {@link #record}, so a failure to parse is a corrupt row. */
    static TeamFont decode(byte[] faces) {
        try {
            return TeamFont.parseFrom(faces);
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException("stored font faces do not parse", e);
        }
    }

    static String hex(ByteString sha256) {
        return HexFormat.of().formatHex(sha256.toByteArray());
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
