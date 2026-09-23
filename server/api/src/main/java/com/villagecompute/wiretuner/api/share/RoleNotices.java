package com.villagecompute.wiretuner.api.share;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.persistence.BranchRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.api.sync.LiveSessions;
import com.villagecompute.wiretuner.api.sync.Participants;
import com.villagecompute.wiretuner.api.sync.PushGrants;
import com.villagecompute.wiretuner.sync.v1.AccessRemoved;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.MembersChanged;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.RoleChanged;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Role changes that reach many people at once (COLLAB-011; sharing.adoc, Server): a team member's
 * role or removal, the team default, a document's team access override, a move between spaces, a
 * link's expiry. Once the change has committed, every account with a live subscription on an
 * affected document is told its effective role there -- {@code RoleChanged}, or
 * {@code AccessRemoved}, which ends that subscription -- and this node forgets its memoised push
 * decisions for the document, so a downgrade is refused on the person's next push. Only live
 * accounts are evaluated ({@link LiveSessions}): nobody else has a session to tell. A document's
 * branches take its roles, so they are told with it (COLLAB-019); a team's documents include them.
 */
@ApplicationScoped
public class RoleNotices {

    @Inject
    DocumentRoles roles;

    @Inject
    DocumentRepository documents;

    @Inject
    DocumentEvents events;

    @Inject
    LiveSessions sessions;

    @Inject
    Participants participants;

    @Inject
    PushGrants grants;

    @Inject
    BranchRepository branches;

    /** Tells the live accounts among {@code accounts} (null = every live account) on every document of the team. */
    public Uni<Void> team(UUID teamId, Set<UUID> accounts, UUID actor) {
        return Panache.withSession(() -> documents.listTeam(teamId))
                .map(docs -> docs.stream().map(doc -> doc.id).toList())
                .chain(ids -> sessions.accounts(ids))
                .chain(live -> tell(live, accounts, actor, false));
    }

    /**
     * Tells the live accounts among {@code accounts} (null = every live account) on the document, and
     * everyone on it that its members changed.
     */
    public Uni<Void> document(UUID documentId, Set<UUID> accounts, UUID actor) {
        return family(documentId).chain(sessions::accounts).chain(live -> tell(live, accounts, actor, true));
    }

    /** The document and its branches, whose roles are its own (COLLAB-019). */
    public Uni<List<UUID>> family(UUID documentId) {
        return Panache.withSession(() -> branches.branchesOf(documentId)).map(ids -> {
            List<UUID> family = new ArrayList<>(ids.size() + 1);
            family.add(documentId);
            family.addAll(ids);
            return family;
        });
    }

    private Uni<Void> tell(Map<UUID, Set<UUID>> live, Set<UUID> accounts, UUID actor, boolean members) {
        live.keySet().forEach(grants::forget);
        return Panache.withSession(() -> (actor == null ? Uni.createFrom().item(Participant.getDefaultInstance())
                : participants.of(actor))
                .flatMap(participant -> Multi.createFrom().iterable(live.entrySet())
                        .onItem().transformToUniAndConcatenate(entry -> notices(entry.getKey(), entry.getValue(), accounts,
                                participant, members))
                        .collect().asList()))
                .chain(all -> Multi.createFrom().iterable(all).onItem().transformToIterable(list -> list)
                        .onItem().transformToUniAndConcatenate(notice -> notice.audience() == null
                                ? events.publish(notice.document(), notice.event())
                                : events.publishTo(notice.document(), notice.audience(), notice.event()))
                        .collect().last())
                .replaceWithVoid();
    }

    /** An event for one document's sessions: one account's ({@code audience}), or everyone's (null). */
    record Notice(UUID document, UUID audience, DocumentEvent event) {
    }

    private Uni<List<Notice>> notices(UUID documentId, Set<UUID> live, Set<UUID> accounts, Participant actor,
            boolean members) {
        List<UUID> targets = live.stream().filter(account -> accounts == null || accounts.contains(account)).sorted().toList();
        Multi<Notice> everyone = Multi.createFrom().iterable(members && !live.isEmpty()
                ? List.of(new Notice(documentId, null, membersChanged(actor))) : List.of());
        Multi<Notice> personal = Multi.createFrom().iterable(targets)
                .onItem().transformToUniAndConcatenate(account -> roles.effectiveRole(documentId, account)
                        .map(role -> new Notice(documentId, account, event(role, actor))));
        return Multi.createBy().concatenating().streams(everyone, personal).collect().asList();
    }

    /** {@code MembersChanged}; an actor that is the default instance is left unset. */
    static DocumentEvent membersChanged(Participant actor) {
        MembersChanged.Builder changed = MembersChanged.newBuilder();
        return DocumentEvent.newBuilder().setMembersChanged(actor.getUserId().isEmpty() ? changed
                : changed.setActor(actor)).build();
    }

    /** The new role for its account's sessions; an actor that is the default instance is left unset. */
    static DocumentEvent event(Role role, Participant actor) {
        boolean known = !actor.getUserId().isEmpty();
        if (role == Role.NONE) {
            AccessRemoved.Builder removed = AccessRemoved.newBuilder();
            return DocumentEvent.newBuilder().setAccessRemoved(known ? removed.setActor(actor) : removed).build();
        }
        RoleChanged.Builder changed = RoleChanged.newBuilder().setRole(DocumentMessages.role(role));
        return DocumentEvent.newBuilder().setRoleChanged(known ? changed.setActor(actor) : changed).build();
    }
}
