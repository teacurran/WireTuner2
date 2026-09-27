package com.villagecompute.wiretuner.api.branch;

import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.docs.DocumentCopies;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.docs.Spaces;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.BranchRepository;
import com.villagecompute.wiretuner.api.persistence.BranchRepository.BranchRow;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.LibraryRepository;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.docs.v1.Branch;
import com.villagecompute.wiretuner.docs.v1.BranchState;
import com.villagecompute.wiretuner.docs.v1.CreateBranchRequest;
import com.villagecompute.wiretuner.docs.v1.CreateBranchResponse;
import com.villagecompute.wiretuner.docs.v1.DeleteBranchRequest;
import com.villagecompute.wiretuner.docs.v1.DeleteBranchResponse;
import com.villagecompute.wiretuner.docs.v1.GetBranchRequest;
import com.villagecompute.wiretuner.docs.v1.GetBranchResponse;
import com.villagecompute.wiretuner.docs.v1.ListBranchesRequest;
import com.villagecompute.wiretuner.docs.v1.ListBranchesResponse;
import com.villagecompute.wiretuner.docs.v1.MergeBranchRequest;
import com.villagecompute.wiretuner.docs.v1.MergeBranchResponse;
import com.villagecompute.wiretuner.docs.v1.MutinyBranchServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.RenameBranchRequest;
import com.villagecompute.wiretuner.docs.v1.RenameBranchResponse;
import com.villagecompute.wiretuner.docs.v1.SetBranchStateRequest;
import com.villagecompute.wiretuner.docs.v1.SetBranchStateResponse;
import com.villagecompute.wiretuner.sync.v1.BranchEvent;
import com.villagecompute.wiretuner.sync.v1.BranchEventKind;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.Participant;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.BranchService} (SRV-011; branches.adoc, Specification). A branch is a
 * document forked from its parent's state at a server_seq ({@link DocumentCopies#branch}) with a
 * {@code branch} row naming the parent. Creating needs editor on the parent; listing, viewer on the
 * parent; reading, viewer on the branch; renaming, archiving and trashing, editor on the branch
 * (whose roles are the parent's, looked up through it); merging ({@link BranchMerge}), editor on the
 * parent. A branch cannot be branched. Every change is told to the parent's and the branch's live
 * sessions as a {@code BranchEvent} once committed (COLLAB-019).
 */
@GrpcService
public class BranchGrpcService extends MutinyBranchServiceGrpc.BranchServiceImplBase {

    /** ListBranches' default page; the proto caps it at 50. */
    static final int DEFAULT_PAGE_SIZE = 50;

    static final Map<String, BranchState> STATES = Map.of(
            "active", BranchState.BRANCH_STATE_ACTIVE,
            "archived", BranchState.BRANCH_STATE_ARCHIVED,
            "merged", BranchState.BRANCH_STATE_MERGED);

    @Inject
    RoleGuard guard;

    @Inject
    BranchRepository branches;

    @Inject
    DocumentRepository documents;

    @Inject
    LibraryRepository library;

    @Inject
    DocumentCopies copies;

    @Inject
    BranchMerge merge;

    @Inject
    DocumentEvents events;

    @Inject
    Spaces spaces;

    @Override
    public Uni<CreateBranchResponse> createBranch(CreateBranchRequest request) {
        UUID parentId = UUID.fromString(request.getParentDocumentId());
        UUID branchId = UUID.fromString(request.getBranchDocumentId());
        return tx(() -> guard.require(parentId, Role.EDITOR).flatMap(grant -> branches.find(branchId).flatMap(existing -> {
            if (existing != null) {
                return existing.parentId().equals(parentId) ? Uni.createFrom().item(new Told(existing, null))
                        : Uni.createFrom().failure(StatusExceptions.documentExists());
            }
            return documents.findById(branchId).flatMap(taken -> taken != null
                    ? Uni.createFrom().failure(StatusExceptions.documentExists())
                    : branches.find(parentId).flatMap(parentBranch -> parentBranch != null
                            ? Uni.createFrom().failure(StatusExceptions.validationFailed("a branch cannot be branched",
                                    Map.of("parent_document_id", "names a branch")))
                            : library.row(parentId).flatMap(parent -> {
                                long at = request.getForkServerSeq() == 0 ? parent.headSeq() : request.getForkServerSeq();
                                if (at > parent.headSeq()) {
                                    return Uni.createFrom().failure(StatusExceptions.historyUnavailable(at, parent.headSeq()));
                                }
                                DocumentCopies.Copy copy = new DocumentCopies.Copy(parent, branchId, parent.spaceId(),
                                        parent.folderId(), request.getName(), at, request.getInitialChangesList(), false);
                                return copies.branch(grant.principal(), copy)
                                        .chain(() -> branches.insert(branchId, parentId, request.getName(), at,
                                                grant.principal().accountId()))
                                        .chain(documents::flush)
                                        .chain(() -> told(grant.principal().accountId(), branchId,
                                                BranchEventKind.BRANCH_EVENT_KIND_CREATED));
                            })));
        }))).call(this::publish).map(told -> CreateBranchResponse.newBuilder().setBranch(branch(told.row())).build());
    }

    @Override
    public Uni<ListBranchesResponse> listBranches(ListBranchesRequest request) {
        int pageSize = Cursors.pageSize(request.getPageSize(), DEFAULT_PAGE_SIZE);
        long afterMicros = Long.MAX_VALUE;
        UUID afterId = new UUID(-1, -1);
        if (!request.getCursor().isEmpty()) {
            String[] parts = Cursors.decode(request.getCursor(), 2);
            afterMicros = Cursors.number(parts[0]);
            afterId = Cursors.uuid(parts[1]);
        }
        long micros = afterMicros;
        UUID after = afterId;
        if (!request.getSpaceId().isEmpty()) {
            UUID spaceId = UUID.fromString(request.getSpaceId());
            return tx(() -> guard.authenticated().flatMap(principal -> spaces.member(principal, spaceId)
                    .chain(() -> branches.listInSpace(principal.accountId(), spaceId, request.getIncludeArchived(), micros,
                            after, pageSize + 1))))
                    .map(rows -> page(rows, pageSize));
        }
        UUID parentId = UUID.fromString(request.getParentDocumentId());
        return tx(() -> guard.require(parentId, Role.VIEWER)
                .chain(() -> branches.list(parentId, request.getIncludeArchived(), micros, after, pageSize + 1)))
                .map(rows -> page(rows, pageSize));
    }

    static ListBranchesResponse page(List<BranchRow> rows, int pageSize) {
        List<BranchRow> shown = rows.size() > pageSize ? rows.subList(0, pageSize) : rows;
        ListBranchesResponse.Builder response = ListBranchesResponse.newBuilder();
        shown.forEach(row -> response.addBranches(branch(row)));
        if (rows.size() > pageSize) {
            BranchRow last = shown.get(shown.size() - 1);
            response.setNextCursor(Cursors.encode(Long.toString(last.createdAtMicros()), last.branchId().toString()));
        }
        return response.build();
    }

    @Override
    public Uni<GetBranchResponse> getBranch(GetBranchRequest request) {
        UUID branchId = UUID.fromString(request.getBranchDocumentId());
        return tx(() -> guard.require(branchId, Role.VIEWER).chain(() -> found(branchId)))
                .map(row -> GetBranchResponse.newBuilder().setBranch(branch(row)).build());
    }

    @Override
    public Uni<RenameBranchResponse> renameBranch(RenameBranchRequest request) {
        UUID branchId = UUID.fromString(request.getBranchDocumentId());
        return tx(() -> guard.require(branchId, Role.EDITOR).flatMap(grant -> found(branchId)
                .chain(() -> branches.rename(branchId, request.getName()))
                .chain(() -> told(grant.principal().accountId(), branchId, BranchEventKind.BRANCH_EVENT_KIND_RENAMED))))
                .call(this::publish)
                .map(told -> RenameBranchResponse.newBuilder().setBranch(branch(told.row())).build());
    }

    @Override
    public Uni<SetBranchStateResponse> setBranchState(SetBranchStateRequest request) {
        UUID branchId = UUID.fromString(request.getBranchDocumentId());
        boolean archived = request.getState() == BranchState.BRANCH_STATE_ARCHIVED;
        return tx(() -> guard.require(branchId, Role.EDITOR).flatMap(grant -> found(branchId)
                .chain(() -> branches.setState(branchId, archived ? "archived" : "active"))
                .chain(() -> told(grant.principal().accountId(), branchId, archived
                        ? BranchEventKind.BRANCH_EVENT_KIND_ARCHIVED : BranchEventKind.BRANCH_EVENT_KIND_RESTORED))))
                .call(this::publish)
                .map(told -> SetBranchStateResponse.newBuilder().setBranch(branch(told.row())).build());
    }

    @Override
    public Uni<DeleteBranchResponse> deleteBranch(DeleteBranchRequest request) {
        UUID branchId = UUID.fromString(request.getBranchDocumentId());
        return tx(() -> guard.require(branchId, Role.EDITOR).flatMap(grant -> found(branchId)
                .chain(() -> documents.update("trashedAt = coalesce(trashedAt, current_timestamp) where id = ?1", branchId))
                .chain(() -> told(grant.principal().accountId(), branchId, BranchEventKind.BRANCH_EVENT_KIND_TRASHED))))
                .call(this::publish)
                .replaceWith(DeleteBranchResponse.getDefaultInstance());
    }

    @Override
    public Uni<MergeBranchResponse> mergeBranch(MergeBranchRequest request) {
        return merge.merge(request);
    }

    /** A branch after a change, and the event its parent's and its own sessions are told (null: none). */
    record Told(BranchRow row, DocumentEvent event) {
    }

    /** The branch as it is now, with the {@code BranchEvent} of {@code kind} by {@code actor}; in the transaction. */
    Uni<Told> told(UUID actor, UUID branchId, BranchEventKind kind) {
        return branches.find(branchId).chain(row -> events.event(actor, participant -> event(row, kind, participant))
                .map(event -> new Told(row, event)));
    }

    /** The {@code BranchEvent} frame of a branch. */
    static DocumentEvent event(BranchRow row, BranchEventKind kind, Participant actor) {
        return DocumentEvent.newBuilder().setBranch(BranchEvent.newBuilder()
                .setBranchDocumentId(row.branchId().toString())
                .setParentDocumentId(row.parentId().toString())
                .setName(row.name())
                .setKind(kind)
                .setActor(actor)).build();
    }

    /** Tells the parent's and the branch's sessions, once committed (COLLAB-019). */
    Uni<Void> publish(Told told) {
        if (told.event() == null) {
            return Uni.createFrom().voidItem();
        }
        return events.publish(told.row().parentId(), told.event())
                .chain(() -> events.publish(told.row().branchId(), told.event()));
    }

    /** The branch row; {@code NOT_FOUND / DOCUMENT_NOT_FOUND} when the document is not a branch. */
    private Uni<BranchRow> found(UUID branchId) {
        return branches.find(branchId).onItem().ifNull().failWith(StatusExceptions::documentNotFound);
    }

    /** The {@code Branch} message of a row. */
    static Branch branch(BranchRow row) {
        Branch.Builder branch = Branch.newBuilder()
                .setBranchDocumentId(row.branchId().toString())
                .setParentDocumentId(row.parentId().toString())
                .setName(row.name())
                .setForkServerSeq(row.forkSeq())
                .setMergedBranchSeq(row.mergedBranchSeq())
                .setMergedParentSeq(row.mergedParentSeq())
                .setState(STATES.get(row.state()))
                .setCreatedByAccountId(row.createdBy())
                .setCreatedAt(DocumentMessages.micros(row.createdAtMicros()))
                .setHeadSeq(row.headSeq());
        if (row.lastChangeAtMicros() != null) {
            branch.setLastChangeAt(DocumentMessages.micros(row.lastChangeAtMicros()));
        }
        if (row.lastAuthorId() != null) {
            branch.setLastAuthorAccountId(row.lastAuthorId().toString()).setLastAuthorDisplayName(row.lastAuthorName());
        }
        return branch.build();
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
