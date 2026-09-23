package com.villagecompute.wiretuner.api.library;

import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import com.google.protobuf.InvalidProtocolBufferException;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.history.DocumentStates;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.TeamColorLibrary;
import com.villagecompute.wiretuner.api.persistence.TeamColorLibraryRepository;
import com.villagecompute.wiretuner.api.persistence.TeamColorLibraryRepository.Listed;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryInfo;
import com.villagecompute.wiretuner.docs.v1.ColorLibraryMode;
import com.villagecompute.wiretuner.docs.v1.FetchColorLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.FetchColorLibraryResponse;
import com.villagecompute.wiretuner.docs.v1.ListColorLibrariesRequest;
import com.villagecompute.wiretuner.docs.v1.ListColorLibrariesResponse;
import com.villagecompute.wiretuner.docs.v1.MutinyColorLibraryServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.PublishColorLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.PublishColorLibraryResponse;
import com.villagecompute.wiretuner.docs.v1.UnpublishColorLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.UnpublishColorLibraryResponse;
import com.villagecompute.wiretuner.lib.v1.ColorLibrary;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.ColorLibraryService} (COLOR-020; exporting-colors.adoc, Team color
 * libraries). A color library is a {@code color_library} row on a document. Publishing and
 * unpublishing need the owner's powers on the document; listing and fetching need membership of the
 * library's team above guest and no role on the document: consumers never open it. Fetch reads the
 * swatches at the published version through {@code wt-crdt} ({@link DocumentStates},
 * {@link ColorLibraries}); in automatic mode that version is the head, read when asked, and in
 * manual mode the colors were extracted when the version was published and are stored with it.
 */
@GrpcService
public class ColorLibraryGrpcService extends MutinyColorLibraryServiceGrpc.ColorLibraryServiceImplBase {

    static final String NO_TEAM = "a personal document is published to a team: name the team";
    static final String OTHER_TEAM = "a team document is published to its own team";

    /** A library found for Fetch, with its stored colors in manual mode. */
    record Found(Listed listed, byte[] colors) {
    }

    @Inject
    RoleGuard guard;

    @Inject
    TeamMembership membership;

    @Inject
    DocumentRepository documents;

    @Inject
    TeamColorLibraryRepository libraries;

    @Inject
    DocumentStates states;

    @Override
    public Uni<PublishColorLibraryResponse> publishColorLibrary(PublishColorLibraryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(documentId, Role.OWNER)
                .flatMap(grant -> documents.findById(documentId).flatMap(doc -> publish(grant.principal(), doc, request)))
                .chain(() -> libraries.listed(documentId))
                .onItem().ifNull().failWith(StatusExceptions::documentNotFound))
                .map(listed -> PublishColorLibraryResponse.newBuilder().setLibrary(info(listed)).build());
    }

    private Uni<Void> publish(Principal principal, Document doc, PublishColorLibraryRequest request) {
        UUID teamId = request.getTeamId().isEmpty() ? doc.teamId : UUID.fromString(request.getTeamId());
        if (teamId == null) {
            return Uni.createFrom().failure(StatusExceptions.teamRoleInvalid(NO_TEAM));
        }
        if (doc.teamId != null && !doc.teamId.equals(teamId)) {
            return Uni.createFrom().failure(StatusExceptions.teamRoleInvalid(OTHER_TEAM));
        }
        Uni<Void> member = doc.teamId == null ? membership.require(principal, teamId) : Uni.createFrom().voidItem();
        return member.chain(() -> libraries.findById(doc.id)).flatMap(existing -> {
            TeamColorLibrary library = existing != null ? existing : created(doc);
            if (!request.getName().isEmpty()) {
                library.name = request.getName();
            }
            if (request.getMode() != ColorLibraryMode.COLOR_LIBRARY_MODE_UNSPECIFIED) {
                library.manual = request.getMode() == ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL;
            }
            library.teamId = teamId;
            library.publishedBy = principal.accountId();
            library.publishedAt = Instant.now();
            return version(library, doc, request.getServerSeq()).chain(() -> libraries.persistAndFlush(library))
                    .replaceWithVoid();
        });
    }

    private static TeamColorLibrary created(Document doc) {
        TeamColorLibrary library = new TeamColorLibrary();
        library.documentId = doc.id;
        library.name = doc.name;
        return library;
    }

    /** Manual mode: extracts and stores the colors at the requested seq (0 = the head). Automatic: clears both. */
    private Uni<Void> version(TeamColorLibrary library, Document doc, long requested) {
        if (!library.manual) {
            library.publishedSeq = 0;
            library.colors = null;
            return Uni.createFrom().voidItem();
        }
        long seq = requested == 0 ? doc.headSeq : requested;
        if (Long.compareUnsigned(seq, doc.headSeq) > 0) {
            return Uni.createFrom().failure(StatusExceptions.validationFailed("server_seq is past the document's head",
                    Map.of("server_seq", "must be at most the head, " + doc.headSeq)));
        }
        return states.at(doc.id, seq).invoke(engine -> {
            library.publishedSeq = seq;
            library.colors = ColorLibraries.extract(engine.store(), library.name).toByteArray();
        }).replaceWithVoid();
    }

    @Override
    public Uni<UnpublishColorLibraryResponse> unpublishColorLibrary(UnpublishColorLibraryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(documentId, Role.OWNER).chain(() -> libraries.deleteById(documentId)))
                .replaceWith(UnpublishColorLibraryResponse.getDefaultInstance());
    }

    @Override
    public Uni<ListColorLibrariesResponse> listColorLibraries(ListColorLibrariesRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> guard.authenticated().flatMap(principal -> membership.require(principal, teamId))
                .chain(() -> libraries.page(teamId, offset, pageSize + 1)))
                .map(rows -> {
                    ListColorLibrariesResponse.Builder response = ListColorLibrariesResponse.newBuilder();
                    if (rows.size() > pageSize) {
                        response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                    }
                    rows.subList(0, Math.min(rows.size(), pageSize)).forEach(row -> response.addLibraries(info(row)));
                    return response.build();
                });
    }

    @Override
    public Uni<FetchColorLibraryResponse> fetchColorLibrary(FetchColorLibraryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.authenticated().flatMap(principal -> libraries.listed(documentId)
                .onItem().ifNull().failWith(StatusExceptions::documentNotFound)
                .call(listed -> membership.require(principal, listed.teamId())
                        .onFailure(ColorLibraryGrpcService::outsider).transform(e -> StatusExceptions.documentNotFound()))
                .flatMap(listed -> listed.manual()
                        ? libraries.findById(documentId).map(row -> new Found(listed, row.colors))
                        : Uni.createFrom().item(new Found(listed, null)))))
                .flatMap(found -> {
                    ColorLibraryInfo info = info(found.listed());
                    FetchColorLibraryResponse.Builder response = FetchColorLibraryResponse.newBuilder().setLibrary(info);
                    if (request.getKnownSeq() != 0 && request.getKnownSeq() == info.getPublishedSeq()) {
                        return Uni.createFrom().item(response.build());
                    }
                    Uni<ColorLibrary> colors = found.colors() != null ? Uni.createFrom().item(decode(found.colors()))
                            : states.at(documentId, info.getPublishedSeq())
                                    .map(engine -> ColorLibraries.extract(engine.store(), info.getName()));
                    return colors.map(library -> response.setColors(library.toBuilder().setName(info.getName())).build());
                });
    }

    /** Whether a membership failure is the caller's not belonging to the team: the library then reads as absent. */
    static boolean outsider(Throwable failure) {
        return StatusExceptions.reasonOf(failure).filter(ErrorReasons.TEAM_NOT_FOUND::equals).isPresent();
    }

    /** Stored colors; they were written by {@link ColorLibraries}, so a failure to parse is a corrupt row. */
    static ColorLibrary decode(byte[] colors) {
        try {
            return ColorLibrary.parseFrom(colors);
        } catch (InvalidProtocolBufferException e) {
            throw new IllegalStateException("stored color library does not parse", e);
        }
    }

    /**
     * The library as listed. Automatic mode publishes the head, and its version dates from the later of
     * the last Publish call and the head change being sequenced (the latter unknown once compacted away).
     */
    static ColorLibraryInfo info(Listed listed) {
        long seq = listed.manual() ? listed.publishedSeq() : listed.headSeq();
        long updated = listed.manual() || listed.headMillis() == null ? listed.publishedMillis()
                : Math.max(listed.publishedMillis(), listed.headMillis());
        return ColorLibraryInfo.newBuilder()
                .setDocumentId(listed.documentId().toString())
                .setTeamId(listed.teamId().toString())
                .setName(listed.name())
                .setPublishedSeq(seq)
                .setUpdatedMs(updated)
                .setMode(listed.manual() ? ColorLibraryMode.COLOR_LIBRARY_MODE_MANUAL
                        : ColorLibraryMode.COLOR_LIBRARY_MODE_AUTOMATIC)
                .setPublishedByAccountId(listed.publishedBy() == null ? "" : listed.publishedBy().toString())
                .build();
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
