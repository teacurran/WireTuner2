package com.villagecompute.wiretuner.api.library;

import java.time.Instant;
import java.util.HexFormat;
import java.util.UUID;
import java.util.function.Supplier;

import com.google.protobuf.ByteString;
import com.google.protobuf.Timestamp;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.auth.WorkspacePolicy;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.TeamLibrary;
import com.villagecompute.wiretuner.api.persistence.TeamLibraryRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.team.TeamRoles;
import com.villagecompute.wiretuner.docs.v1.GetLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.GetLibraryResponse;
import com.villagecompute.wiretuner.docs.v1.Library;
import com.villagecompute.wiretuner.docs.v1.ListLibrariesRequest;
import com.villagecompute.wiretuner.docs.v1.ListLibrariesResponse;
import com.villagecompute.wiretuner.docs.v1.MutinyLibraryServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.SetLibraryRequest;
import com.villagecompute.wiretuner.docs.v1.SetLibraryResponse;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.LibraryService} (COLLAB-012; sharing.adoc, Team libraries). A library is a
 * team document with a {@code library} row (and {@code document.is_library} set, for the library
 * window). Publishing needs the owner's powers on the document -- its owner row or a team admin --
 * and a team document; listing needs membership of the team above guest; getting needs a role on the
 * document. Nothing here touches document content: consumers copy from a library (copies keep
 * working when it is unpublished) and read it through {@code SyncService} like any document they can
 * view. Every team member can: the team default is at least viewer (the schema has no lower one),
 * so publishing leaves the document's team access as it is.
 */
@GrpcService
public class LibraryGrpcService extends MutinyLibraryServiceGrpc.LibraryServiceImplBase {

    static final String PERSONAL_DOCUMENT = "a personal document cannot be a team library; move it to a team first";

    @Inject
    RoleGuard guard;

    @Inject
    WorkspacePolicy workspaces;

    @Inject
    DocumentRepository documents;

    @Inject
    TeamLibraryRepository libraries;

    @Inject
    TeamMemberRepository teamMembers;

    @Override
    public Uni<SetLibraryResponse> setLibrary(SetLibraryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(documentId, Role.OWNER).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> {
                    if (doc.teamId == null) {
                        return Uni.createFrom().failure(StatusExceptions.teamRoleInvalid(PERSONAL_DOCUMENT));
                    }
                    doc.library = request.getIsLibrary();
                    doc.updatedAt = Instant.now();
                    return libraries.findById(documentId).flatMap(existing -> request.getIsLibrary()
                            ? publish(grant.principal(), doc, existing, request.getName())
                            : unpublish(existing));
                })))
                .map(library -> library == null ? SetLibraryResponse.getDefaultInstance()
                        : SetLibraryResponse.newBuilder().setLibrary(library).build());
    }

    private Uni<Library> publish(Principal principal, Document doc, TeamLibrary existing, String name) {
        TeamLibrary library = existing != null ? existing : new TeamLibrary();
        library.name = name.isEmpty() ? doc.name : name;
        if (existing != null) {
            return Uni.createFrom().item(message(library, doc));
        }
        library.documentId = doc.id;
        library.teamId = doc.teamId;
        library.publishedBy = principal.accountId();
        return libraries.persist(library).map(saved -> message(saved, doc));
    }

    private Uni<Library> unpublish(TeamLibrary existing) {
        return (existing == null ? Uni.createFrom().voidItem() : libraries.delete(existing)).replaceWith((Library) null);
    }

    @Override
    public Uni<ListLibrariesResponse> listLibraries(ListLibrariesRequest request) {
        UUID teamId = UUID.fromString(request.getTeamId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> guard.authenticated().flatMap(principal -> member(principal, teamId))
                .chain(() -> libraries.page(teamId, offset, pageSize + 1)))
                .map(rows -> {
                    ListLibrariesResponse.Builder response = ListLibrariesResponse.newBuilder();
                    if (rows.size() > pageSize) {
                        response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                    }
                    rows.subList(0, Math.min(rows.size(), pageSize))
                            .forEach(row -> response.addLibraries(message((TeamLibrary) row[0], (Document) row[1])));
                    return response.build();
                });
    }

    /**
     * The caller's membership of the team, above guest: {@code TEAM_NOT_FOUND} for an outsider,
     * {@code ROLE_INSUFFICIENT} for a guest; a workspace that requires SSO holds members to it.
     */
    private Uni<Void> member(Principal principal, UUID teamId) {
        return teamMembers.findById(new TeamMemberId(teamId, principal.accountId())).flatMap(member -> {
            if (member == null) {
                return Uni.createFrom().failure(StatusExceptions.teamNotFound());
            }
            if (!TeamRoles.atLeast(member.role, TeamRoles.MEMBER)) {
                return Uni.createFrom().failure(StatusExceptions.roleInsufficient(TeamRoles.MEMBER, member.role));
            }
            return workspaces.requireSso(principal, teamId);
        });
    }

    @Override
    public Uni<GetLibraryResponse> getLibrary(GetLibraryRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(documentId, Role.VIEWER)
                .chain(() -> libraries.findById(documentId))
                .onItem().ifNull().failWith(StatusExceptions::documentNotFound)
                .flatMap(library -> documents.findById(documentId).map(doc -> message(library, doc))))
                .map(library -> GetLibraryResponse.newBuilder().setLibrary(library).build());
    }

    static Library message(TeamLibrary library, Document doc) {
        Library.Builder out = Library.newBuilder()
                .setDocumentId(doc.id.toString())
                .setTeamId(library.teamId.toString())
                .setName(library.name)
                .setKind(DocumentMessages.kind(doc.kind))
                .setHeadSeq(doc.headSeq)
                .setPublishedAt(Timestamp.newBuilder().setSeconds(library.publishedAt.getEpochSecond())
                        .setNanos(library.publishedAt.getNano()))
                .setPublishedByAccountId(library.publishedBy == null ? "" : library.publishedBy.toString());
        if (doc.thumbnailBlob != null) {
            out.setThumbnailBlob(ByteString.copyFrom(HexFormat.of().parseHex(doc.thumbnailBlob)));
        }
        return out.build();
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
