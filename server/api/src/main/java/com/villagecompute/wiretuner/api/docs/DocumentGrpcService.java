package com.villagecompute.wiretuner.api.docs;

import static com.villagecompute.wiretuner.api.docs.DocumentMessages.optionalUuid;

import java.time.Instant;
import java.util.List;
import java.util.UUID;
import java.util.function.Function;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentMember;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberId;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.Folder;
import com.villagecompute.wiretuner.api.persistence.FolderRepository;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.DocumentRow;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository.Scope;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.docs.v1.CreateFolderRequest;
import com.villagecompute.wiretuner.docs.v1.CreateFolderResponse;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.CreateResponse;
import com.villagecompute.wiretuner.docs.v1.DeleteFolderRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteFolderResponse;
import com.villagecompute.wiretuner.docs.v1.DuplicateRequest;
import com.villagecompute.wiretuner.docs.v1.DuplicateResponse;
import com.villagecompute.wiretuner.docs.v1.ForkRequest;
import com.villagecompute.wiretuner.docs.v1.ForkResponse;
import com.villagecompute.wiretuner.docs.v1.GetRequest;
import com.villagecompute.wiretuner.docs.v1.GetResponse;
import com.villagecompute.wiretuner.docs.v1.ListRequest;
import com.villagecompute.wiretuner.docs.v1.ListResponse;
import com.villagecompute.wiretuner.docs.v1.ListScope;
import com.villagecompute.wiretuner.docs.v1.MoveToFolderRequest;
import com.villagecompute.wiretuner.docs.v1.MoveToFolderResponse;
import com.villagecompute.wiretuner.docs.v1.MutinyDocumentServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.RenameFolderRequest;
import com.villagecompute.wiretuner.docs.v1.RenameFolderResponse;
import com.villagecompute.wiretuner.docs.v1.RenameRequest;
import com.villagecompute.wiretuner.docs.v1.RenameResponse;
import com.villagecompute.wiretuner.docs.v1.RestoreRequest;
import com.villagecompute.wiretuner.docs.v1.RestoreResponse;
import com.villagecompute.wiretuner.docs.v1.SearchRequest;
import com.villagecompute.wiretuner.docs.v1.SearchResponse;
import com.villagecompute.wiretuner.docs.v1.SetTemplateRequest;
import com.villagecompute.wiretuner.docs.v1.SetTemplateResponse;
import com.villagecompute.wiretuner.docs.v1.TrashRequest;
import com.villagecompute.wiretuner.docs.v1.TrashResponse;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.Moved;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.Renamed;
import com.villagecompute.wiretuner.sync.v1.Trashed;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.DocumentService} (SRV-009; docs/spec/server.adoc, Services and Search).
 * Every RPC runs in one transaction and checks the caller through {@link RoleGuard} (document
 * RPCs) or {@link Spaces} (space RPCs) before touching a row. Rename, move, trash and restore tell
 * every live session on the document (Renamed, Moved, Trashed) once their transaction commits.
 */
@GrpcService
public class DocumentGrpcService extends MutinyDocumentServiceGrpc.DocumentServiceImplBase {

    /** List's default page; the proto caps it at 100. */
    static final int LIST_PAGE = 50;
    /** Search's default page; the proto caps it at 50. */
    static final int SEARCH_PAGE = 20;
    static final UUID NIL = new UUID(0, 0);

    @Inject
    RoleGuard guard;

    @Inject
    DocumentRoles roles;

    @Inject
    Spaces spaces;

    @Inject
    LibraryRepository library;

    @Inject
    DocumentRepository documents;

    @Inject
    DocumentMemberRepository members;

    @Inject
    FolderRepository folders;

    @Inject
    DocumentCopies copies;

    @Inject
    LibrarySearch search;

    @Inject
    DocumentEvents events;

    @Override
    public Uni<CreateResponse> create(CreateRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        UUID spaceId = UUID.fromString(request.getSpaceId());
        UUID folderId = optionalUuid(request.getFolderId());
        return tx(() -> guard.authenticated().flatMap(principal -> documents.findById(id).flatMap(existing -> {
            if (existing != null) {
                return copies.retried(principal, existing, spaceId, request.hasInitialChange()
                        ? request.getInitialChange() : null);
            }
            return spaces.creatable(principal, spaceId)
                    .flatMap(space -> spaces.folderIn(folderId, spaceId).replaceWith(space))
                    .flatMap(space -> copies.create(principal, id, space, folderId, request));
        }).flatMap(created -> view(principal, created))))
                .map(doc -> CreateResponse.newBuilder().setDocument(doc).build());
    }

    @Override
    public Uni<ListResponse> list(ListRequest request) {
        Scope scope = scope(request.getScope());
        int pageSize = Cursors.pageSize(request.getPageSize(), LIST_PAGE);
        String afterName = "";
        UUID afterId = NIL;
        if (!request.getCursor().isEmpty()) {
            String[] parts = Cursors.decode(request.getCursor(), 2);
            afterName = parts[0];
            afterId = Cursors.uuid(parts[1]);
        }
        UUID spaceId = optionalUuid(request.getSpaceId());
        UUID folderId = optionalUuid(request.getFolderId());
        String name = afterName;
        UUID after = afterId;
        boolean firstPage = request.getCursor().isEmpty();
        return tx(() -> guard.authenticated().flatMap(principal -> {
            Uni<Spaces.Space> space = scope == Scope.SHARED_WITH_ME
                    ? Uni.createFrom().nullItem()
                    : spaces.member(principal, spaceId)
                            .flatMap(s -> spaces.folderIn(scope == Scope.FOLDER ? folderId : null, spaceId).replaceWith(s));
            return space.flatMap(s -> library.page(new LibraryRepository.PageQuery(principal.accountId(), scope, spaceId,
                            folderId, name, after, pageSize + 1))
                    .flatMap(rows -> page(principal, rows, pageSize))
                    .flatMap(response -> scope == Scope.FOLDER && firstPage && s.creatable()
                            ? folders.listChildren(spaceId, folderId).map(children -> withFolders(response, children))
                            : Uni.createFrom().item(response)));
        })).map(ListResponse.Builder::build);
    }

    static Scope scope(ListScope scope) {
        return switch (scope) {
            case LIST_SCOPE_TRASH -> Scope.TRASH;
            case LIST_SCOPE_TEMPLATES -> Scope.TEMPLATES;
            case LIST_SCOPE_SHARED_WITH_ME -> Scope.SHARED_WITH_ME;
            default -> Scope.FOLDER;
        };
    }

    private Uni<ListResponse.Builder> page(Principal principal, List<DocumentRow> rows, int pageSize) {
        List<DocumentRow> shown = rows.size() > pageSize ? rows.subList(0, pageSize) : rows;
        ListResponse.Builder response = ListResponse.newBuilder();
        if (rows.size() > pageSize) {
            DocumentRow last = shown.get(shown.size() - 1);
            response.setNextCursor(Cursors.encode(last.name(), last.id().toString()));
        }
        return Multi.createFrom().iterable(shown)
                .onItem().transformToUniAndConcatenate(row -> roles.effectiveRole(row.id(), principal.accountId())
                        .map(role -> DocumentMessages.document(row, role)))
                .collect().asList()
                .map(response::addAllDocuments);
    }

    private static ListResponse.Builder withFolders(ListResponse.Builder response, List<Folder> children) {
        children.forEach(folder -> response.addFolders(DocumentMessages.folder(folder)));
        return response;
    }

    @Override
    public Uni<GetResponse> get(GetRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(id, Role.VIEWER).flatMap(grant -> view(grant.principal(), id)))
                .map(doc -> GetResponse.newBuilder().setDocument(doc).build());
    }

    @Override
    public Uni<RenameResponse> rename(RenameRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(id, Role.EDITOR).flatMap(grant -> documents.findById(id)
                .invoke(doc -> touch(doc).name = request.getName())
                .flatMap(doc -> view(grant.principal(), id))
                .flatMap(doc -> announce(grant.principal(), doc, actor -> DocumentEvent.newBuilder()
                        .setRenamed(Renamed.newBuilder().setName(doc.getName()).setActor(actor)).build()))))
                .call(this::publish)
                .map(done -> RenameResponse.newBuilder().setDocument(done.document()).build());
    }

    @Override
    public Uni<MoveToFolderResponse> moveToFolder(MoveToFolderRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        UUID requestedSpace = optionalUuid(request.getSpaceId());
        UUID folderId = optionalUuid(request.getFolderId());
        return tx(() -> guard.require(id, Role.EDITOR).flatMap(grant -> library.row(id).flatMap(row -> {
            UUID destination = requestedSpace == null ? row.spaceId() : requestedSpace;
            Uni<Void> allowed = Uni.createFrom().voidItem();
            boolean crossSpace = !destination.equals(row.spaceId());
            if (crossSpace) {
                if (!grant.role().atLeast(Role.OWNER)) {
                    return Uni.createFrom().failure(StatusExceptions.roleInsufficient(Role.OWNER.dbName(),
                            grant.role().dbName()));
                }
                allowed = spaces.creatable(grant.principal(), destination).replaceWithVoid();
            }
            return allowed.chain(() -> spaces.folderIn(folderId, destination))
                    .chain(() -> documents.findById(id))
                    .chain(doc -> (crossSpace ? moveSpace(grant.principal(), doc, row, destination)
                            : Uni.createFrom().voidItem())
                            .invoke(() -> touch(doc).folderId = folderId))
                    .chain(() -> view(grant.principal(), id))
                    .chain(doc -> announce(grant.principal(), doc, actor -> DocumentEvent.newBuilder()
                            .setMoved(Moved.newBuilder().setSpaceId(doc.getSpaceId()).setFolderId(doc.getFolderId())
                                    .setActor(actor)).build()));
        }))).call(this::publish).map(done -> MoveToFolderResponse.newBuilder().setDocument(done.document()).build());
    }

    /**
     * Moves the document into another space the caller may create in. Named members keep their
     * rows; exactly one owner survives: moving into the caller's personal space makes the caller
     * the owner (a previous team owner row becomes an editor), moving into a team keeps the
     * current owner as the team document's owner row.
     */
    private Uni<Void> moveSpace(Principal principal, Document doc, DocumentRow row, UUID destination) {
        UUID previousOwner = row.documentOwnerId();
        if (destination.equals(principal.accountId())) {
            doc.ownerAccountId = destination;
            doc.teamId = null;
            return members.delete("id.documentId = ?1 and id.accountId = ?2", doc.id, destination)
                    .chain(() -> previousOwner == null || previousOwner.equals(destination)
                            ? Uni.createFrom().voidItem()
                            : setMemberRole(doc.id, previousOwner, Role.EDITOR));
        }
        doc.ownerAccountId = null;
        doc.teamId = destination;
        return previousOwner == null ? Uni.createFrom().voidItem() : setMemberRole(doc.id, previousOwner, Role.OWNER);
    }

    private Uni<Void> setMemberRole(UUID documentId, UUID accountId, Role role) {
        DocumentMemberId key = new DocumentMemberId(documentId, accountId);
        return members.findById(key).chain(member -> {
            if (member != null) {
                member.role = role.dbName();
                return Uni.createFrom().voidItem();
            }
            DocumentMember fresh = new DocumentMember();
            fresh.id = key;
            fresh.role = role.dbName();
            return members.persist(fresh).replaceWithVoid();
        });
    }

    @Override
    public Uni<TrashResponse> trash(TrashRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(id, Role.OWNER).flatMap(grant -> documents.findById(id)
                .invoke(doc -> {
                    if (doc.trashedAt == null) {
                        doc.trashedAt = touch(doc).updatedAt;
                    }
                })
                .flatMap(doc -> view(grant.principal(), id))
                .flatMap(doc -> announce(grant.principal(), doc, actor -> trashed(true, actor)))))
                .call(this::publish)
                .map(done -> TrashResponse.newBuilder().setDocument(done.document()).build());
    }

    @Override
    public Uni<RestoreResponse> restore(RestoreRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(id, Role.OWNER).flatMap(grant -> documents.findById(id)
                .invoke(doc -> touch(doc).trashedAt = null)
                .flatMap(doc -> view(grant.principal(), id))
                .flatMap(doc -> announce(grant.principal(), doc, actor -> trashed(false, actor)))))
                .call(this::publish)
                .map(done -> RestoreResponse.newBuilder().setDocument(done.document()).build());
    }

    @Override
    public Uni<SetTemplateResponse> setTemplate(SetTemplateRequest request) {
        UUID id = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(id, Role.EDITOR).flatMap(grant -> documents.findById(id)
                .invoke(doc -> touch(doc).template = request.getIsTemplate())
                .flatMap(doc -> view(grant.principal(), id))))
                .map(doc -> SetTemplateResponse.newBuilder().setDocument(doc).build());
    }

    @Override
    public Uni<ForkResponse> fork(ForkRequest request) {
        UUID sourceId = UUID.fromString(request.getSourceDocumentId());
        UUID newId = UUID.fromString(request.getNewDocumentId());
        UUID requestedSpace = optionalUuid(request.getSpaceId());
        UUID folderId = optionalUuid(request.getFolderId());
        return tx(() -> guard.require(sourceId, Role.VIEWER).flatMap(grant -> library.row(sourceId).flatMap(source -> {
            Principal principal = grant.principal();
            UUID destination = requestedSpace == null ? principal.accountId() : requestedSpace;
            long at = request.getAtServerSeq() == 0 ? source.headSeq() : request.getAtServerSeq();
            String name = request.getName().isEmpty() ? source.name() : request.getName();
            DocumentCopies.Copy copy = new DocumentCopies.Copy(source, newId, destination, folderId, name, at,
                    request.getChangesList(), false);
            return copies.copy(principal, copy).flatMap(created -> view(principal, created));
        }))).map(doc -> ForkResponse.newBuilder().setDocument(doc).build());
    }

    @Override
    public Uni<DuplicateResponse> duplicate(DuplicateRequest request) {
        UUID sourceId = UUID.fromString(request.getDocumentId());
        UUID newId = UUID.fromString(request.getNewDocumentId());
        UUID requestedSpace = optionalUuid(request.getSpaceId());
        UUID requestedFolder = optionalUuid(request.getFolderId());
        return tx(() -> guard.require(sourceId, Role.VIEWER).flatMap(grant -> library.row(sourceId).flatMap(source -> {
            Principal principal = grant.principal();
            UUID destination = requestedSpace == null ? source.spaceId() : requestedSpace;
            UUID folderId = requestedFolder != null || !destination.equals(source.spaceId())
                    ? requestedFolder : source.folderId();
            String name = request.getName().isEmpty() ? source.name() + " copy" : request.getName();
            DocumentCopies.Copy copy = new DocumentCopies.Copy(source, newId, destination, folderId, name,
                    source.headSeq(), List.of(), request.getAsTemplate());
            return copies.copy(principal, copy).flatMap(created -> view(principal, created));
        }))).map(doc -> DuplicateResponse.newBuilder().setDocument(doc).build());
    }

    @Override
    public Uni<SearchResponse> search(SearchRequest request) {
        UUID spaceId = UUID.fromString(request.getSpaceId());
        int pageSize = Cursors.pageSize(request.getPageSize(), SEARCH_PAGE);
        float afterRank = Float.POSITIVE_INFINITY;
        UUID afterId = NIL;
        if (!request.getCursor().isEmpty()) {
            String[] parts = Cursors.decode(request.getCursor(), 2);
            afterRank = Cursors.real(parts[0]);
            afterId = Cursors.uuid(parts[1]);
        }
        float rank = afterRank;
        UUID after = afterId;
        return tx(() -> guard.authenticated().flatMap(principal -> spaces.member(principal, spaceId)
                .flatMap(space -> search.search(principal, spaceId, request.getQuery(), rank, after, pageSize))));
    }

    @Override
    public Uni<CreateFolderResponse> createFolder(CreateFolderRequest request) {
        UUID spaceId = UUID.fromString(request.getSpaceId());
        UUID parentId = optionalUuid(request.getParentFolderId());
        return tx(() -> guard.authenticated().flatMap(principal -> spaces.creatable(principal, spaceId)
                .flatMap(space -> spaces.folderIn(parentId, spaceId).replaceWith(space))
                .flatMap(space -> {
                    Folder folder = new Folder();
                    folder.id = UUID.randomUUID();
                    folder.ownerAccountId = space.team() ? null : spaceId;
                    folder.teamId = space.team() ? spaceId : null;
                    folder.parentFolderId = parentId;
                    folder.name = request.getName();
                    return folders.persist(folder);
                })))
                .map(folder -> CreateFolderResponse.newBuilder().setFolder(DocumentMessages.folder(folder)).build());
    }

    @Override
    public Uni<RenameFolderResponse> renameFolder(RenameFolderRequest request) {
        UUID id = UUID.fromString(request.getFolderId());
        return tx(() -> guard.authenticated().flatMap(principal -> folders.findById(id).flatMap(folder -> folder == null
                ? Uni.createFrom().<Folder>failure(StatusExceptions.folderNotFound())
                : spaces.creatable(principal, Spaces.spaceOf(folder), StatusExceptions::folderNotFound)
                        .map(space -> {
                            folder.name = request.getName();
                            return folder;
                        }))))
                .map(folder -> RenameFolderResponse.newBuilder().setFolder(DocumentMessages.folder(folder)).build());
    }

    @Override
    public Uni<DeleteFolderResponse> deleteFolder(DeleteFolderRequest request) {
        UUID id = UUID.fromString(request.getFolderId());
        return tx(() -> guard.authenticated().flatMap(principal -> folders.findById(id).flatMap(folder -> folder == null
                ? Uni.createFrom().voidItem()
                : spaces.creatable(principal, Spaces.spaceOf(folder), StatusExceptions::folderNotFound)
                        .chain(() -> documents.update("folderId = ?1, updatedAt = ?2 where folderId = ?3",
                                folder.parentFolderId, Instant.now(), id))
                        .chain(() -> folders.update("parentFolderId = ?1 where parentFolderId = ?2",
                                folder.parentFolderId, id))
                        .chain(() -> folders.delete(folder)))))
                .replaceWith(DeleteFolderResponse.getDefaultInstance());
    }

    /** A committed change to a document and the event every live session on it is told (SRV-005). */
    record Announced(com.villagecompute.wiretuner.docs.v1.Document document, DocumentEvent event) {
    }

    /** Builds the event inside the transaction, with the caller as its actor. */
    private Uni<Announced> announce(Principal principal, com.villagecompute.wiretuner.docs.v1.Document doc,
            Function<Participant, DocumentEvent> event) {
        return events.event(principal.accountId(), event).map(built -> new Announced(doc, built));
    }

    /** Publishes the event once the transaction has committed. */
    private Uni<Void> publish(Announced done) {
        return events.publish(UUID.fromString(done.document().getId()), done.event());
    }

    private static DocumentEvent trashed(boolean trashed, Participant actor) {
        return DocumentEvent.newBuilder().setTrashed(Trashed.newBuilder().setTrashed(trashed).setActor(actor)).build();
    }

    /** The document as the caller sees it now, after flushing this transaction's writes. */
    private Uni<com.villagecompute.wiretuner.docs.v1.Document> view(Principal principal, UUID id) {
        return documents.flush()
                .chain(() -> library.row(id))
                .flatMap(row -> roles.effectiveRole(id, principal.accountId())
                        .map(role -> DocumentMessages.document(row, role)));
    }

    private static Document touch(Document doc) {
        doc.updatedAt = Instant.now();
        return doc;
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
