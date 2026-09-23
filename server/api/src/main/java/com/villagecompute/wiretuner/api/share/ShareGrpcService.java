package com.villagecompute.wiretuner.api.share;

import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.auth.DocumentRoles;
import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.auth.WorkspacePolicy;
import com.villagecompute.wiretuner.api.docs.DocumentMessages;
import com.villagecompute.wiretuner.api.grpc.Cursors;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Account;
import com.villagecompute.wiretuner.api.persistence.AccountRepository;
import com.villagecompute.wiretuner.api.persistence.AccessRequest;
import com.villagecompute.wiretuner.api.persistence.AccessRequestRepository;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.api.persistence.DocumentInvite;
import com.villagecompute.wiretuner.api.persistence.DocumentInviteRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentMember;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberId;
import com.villagecompute.wiretuner.api.persistence.DocumentMemberRepository;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLink;
import com.villagecompute.wiretuner.api.persistence.ShareLinkRepository;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUse;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseId;
import com.villagecompute.wiretuner.api.persistence.ShareLinkUseRepository;
import com.villagecompute.wiretuner.api.persistence.Team;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;
import com.villagecompute.wiretuner.api.sync.DocumentEvents;
import com.villagecompute.wiretuner.api.sync.PushGrants;
import com.villagecompute.wiretuner.api.team.TeamRoles;
import com.villagecompute.wiretuner.docs.v1.CreateLinkRequest;
import com.villagecompute.wiretuner.docs.v1.CreateLinkResponse;
import com.villagecompute.wiretuner.docs.v1.InviteRequest;
import com.villagecompute.wiretuner.docs.v1.InviteResponse;
import com.villagecompute.wiretuner.docs.v1.ListAccessRequestsRequest;
import com.villagecompute.wiretuner.docs.v1.ListAccessRequestsResponse;
import com.villagecompute.wiretuner.docs.v1.ListLinksRequest;
import com.villagecompute.wiretuner.docs.v1.ListLinksResponse;
import com.villagecompute.wiretuner.docs.v1.ListMembersRequest;
import com.villagecompute.wiretuner.docs.v1.ListMembersResponse;
import com.villagecompute.wiretuner.docs.v1.Member;
import com.villagecompute.wiretuner.docs.v1.MutinyShareServiceGrpc;
import com.villagecompute.wiretuner.docs.v1.OpenLinkRequest;
import com.villagecompute.wiretuner.docs.v1.OpenLinkResponse;
import com.villagecompute.wiretuner.docs.v1.RemoveMemberRequest;
import com.villagecompute.wiretuner.docs.v1.RemoveMemberResponse;
import com.villagecompute.wiretuner.docs.v1.RequestAccessRequest;
import com.villagecompute.wiretuner.docs.v1.RequestAccessResponse;
import com.villagecompute.wiretuner.docs.v1.ResolveAccessRequestRequest;
import com.villagecompute.wiretuner.docs.v1.ResolveAccessRequestResponse;
import com.villagecompute.wiretuner.docs.v1.RevokeLinkRequest;
import com.villagecompute.wiretuner.docs.v1.RevokeLinkResponse;
import com.villagecompute.wiretuner.docs.v1.SetRoleRequest;
import com.villagecompute.wiretuner.docs.v1.SetRoleResponse;
import com.villagecompute.wiretuner.docs.v1.TeamAccess;
import com.villagecompute.wiretuner.docs.v1.TransferOwnershipRequest;
import com.villagecompute.wiretuner.docs.v1.TransferOwnershipResponse;
import com.villagecompute.wiretuner.docs.v1.UpdateLinkRequest;
import com.villagecompute.wiretuner.docs.v1.UpdateLinkResponse;
import com.villagecompute.wiretuner.sync.v1.AccessRemoved;
import com.villagecompute.wiretuner.sync.v1.DocumentEvent;
import com.villagecompute.wiretuner.sync.v1.MembersChanged;
import com.villagecompute.wiretuner.sync.v1.Moved;
import com.villagecompute.wiretuner.sync.v1.Participant;
import com.villagecompute.wiretuner.sync.v1.RoleChanged;

import io.quarkus.grpc.GrpcService;
import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Multi;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * {@code wiretuner.docs.v1.ShareService} (SRV-010; sharing.adoc, Data model and Server). Every RPC
 * runs in one transaction behind {@link RoleGuard}; what changed is told to the document's live
 * sessions once the transaction has committed: {@code MembersChanged} to everyone, and to each person
 * whose effective role changed a {@code RoleChanged} (or {@code AccessRemoved}, which ends their
 * subscription). A downgrade is seen by the person's next push: this node forgets its memoised push
 * decisions for the document at once, other nodes within their 2 s grant TTL
 * ({@code wt.sync.grant-ttl}).
 *
 * <p>A team workspace with restrict-sharing refuses invitations of anyone who is not a member of the
 * team, links that anyone outside the team could open, and outsiders opening a link:
 * {@code FAILED_PRECONDITION / TEAM_ROLE_INVALID} (sync.v1 has no dedicated reason yet).
 */
@GrpcService
public class ShareGrpcService extends MutinyShareServiceGrpc.ShareServiceImplBase {

    static final int TOKEN_BYTES = 16;
    static final String SHARING_RESTRICTED = "this workspace restricts sharing to team members";

    private static final SecureRandom RANDOM = new SecureRandom();

    @Inject
    RoleGuard guard;

    @Inject
    DocumentRoles roles;

    @Inject
    WorkspacePolicy workspaces;

    @Inject
    DocumentRepository documents;

    @Inject
    DocumentMemberRepository members;

    @Inject
    DocumentInviteRepository invites;

    @Inject
    ShareLinkRepository links;

    @Inject
    ShareLinkUseRepository linkUses;

    @Inject
    AccessRequestRepository requests;

    @Inject
    AccountRepository accounts;

    @Inject
    TeamRepository teams;

    @Inject
    TeamMemberRepository teamMembers;

    @Inject
    ShareMailer mailer;

    @Inject
    DocumentEvents events;

    @Inject
    PushGrants grants;

    /** An event for one account's sessions ({@code audience}), or for everyone's (null). */
    record Notice(UUID audience, DocumentEvent event) {
    }

    /** A committed RPC's response, and what its document's sessions are told afterwards. */
    record Outcome<T>(T response, UUID documentId, List<Notice> notices) {
    }

    // ---------------------------------------------------------------------------------- members

    @Override
    public Uni<ListMembersResponse> listMembers(ListMembersRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> guard.require(documentId, Role.VIEWER).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> people(doc, grant.role() == Role.OWNER).flatMap(people -> {
                    ListMembersResponse.Builder response = ListMembersResponse.newBuilder();
                    int end = Math.min(people.size(), offset + pageSize);
                    if (end < people.size()) {
                        response.setNextCursor(Cursors.encode(Integer.toString(end)));
                    }
                    response.addAllMembers(people.subList(Math.min(offset, end), end));
                    if (offset > 0 || doc.teamId == null) {
                        return Uni.createFrom().item(response.build());
                    }
                    return teams.findById(doc.teamId).map(team -> response.setTeamAccess(teamAccess(team)).build());
                }))));
    }

    static TeamAccess teamAccess(Team team) {
        return TeamAccess.newBuilder()
                .setTeamId(team.id.toString())
                .setTeamName(team.name)
                .setTeamDefault(DocumentMessages.role(Role.fromDb(team.defaultDocumentRole)))
                .build();
    }

    /**
     * Everyone with access who is known to the document -- its owner, its named members, and people
     * with access through the team or a link who have opened it (their color row, their link use) --
     * the owner first, then by display name, then pending invitations by address.
     */
    private Uni<List<Member>> people(Document doc, boolean owner) {
        return members.getSession().chain(session -> session
                        .createQuery("select u.id.accountId from ShareLinkUse u, ShareLink l"
                                + " where l.id = u.id.shareLinkId and l.documentId = ?1", UUID.class)
                        .setParameter(1, doc.id)
                        .getResultList())
                .flatMap(linkUsers -> members.listForDocument(doc.id).flatMap(rows -> {
                    Set<UUID> ids = new LinkedHashSet<>();
                    if (doc.ownerAccountId != null) {
                        ids.add(doc.ownerAccountId);
                    }
                    rows.forEach(row -> ids.add(row.id.accountId()));
                    ids.addAll(linkUsers);
                    return Multi.createFrom().iterable(ids)
                            .onItem().transformToUniAndConcatenate(id -> person(doc, id, owner))
                            .select().where(person -> person.getEffectiveRole() != DocumentMessages.role(Role.NONE))
                            .collect().asList();
                }))
                .map(found -> found.stream().sorted(Comparator
                        .comparing((Member m) -> m.getRole() != DocumentMessages.role(Role.OWNER))
                        .thenComparing(Member::getDisplayName)
                        .thenComparing(Member::getAccountId)).toList())
                .flatMap(found -> invites.listForDocument(doc.id).map(pending -> {
                    List<Member> all = new ArrayList<>(found);
                    pending.stream().sorted(Comparator.comparing(i -> i.email))
                            .forEach(invite -> all.add(ShareMessages.pending(invite)));
                    return all;
                }));
    }

    /** One person on the document as the People list shows them, with emails for owners. */
    private Uni<Member> person(Document doc, UUID accountId, boolean showEmail) {
        return roles.access(doc, accountId).flatMap(access -> members.findById(new DocumentMemberId(doc.id, accountId))
                .flatMap(row -> accounts.findById(accountId).map(account -> ShareMessages.member(account, access, row,
                        isOwner(doc, accountId, row), showEmail, doc.createdByAccountId))));
    }

    /** The document's one owner: the personal owner, or the team document's {@code owner} row. */
    static boolean isOwner(Document doc, UUID accountId, DocumentMember row) {
        return accountId.equals(doc.ownerAccountId) || row != null && Role.OWNER.dbName().equals(row.role);
    }

    @Override
    public Uni<InviteResponse> invite(InviteRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        Role role = ShareMessages.role(request.getRole());
        return tx(() -> guard.require(documentId, Role.EDITOR).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> invitee(request).flatMap(account -> account == null
                        ? invitePending(grant.principal(), doc, request.getEmail().toLowerCase(Locale.ROOT), role)
                        : inviteAccount(grant.principal(), doc, account, role)))))
                .call(this::announce)
                .call(outcome -> mailInvite(outcome, request))
                .map(outcome -> InviteResponse.newBuilder().setMember(outcome.response()).build());
    }

    /** The account the invitation names: by id (which must exist), or by a verified address, or none. */
    private Uni<Account> invitee(InviteRequest request) {
        if (request.hasAccountId()) {
            return accounts.findById(UUID.fromString(request.getAccountId()))
                    .onItem().ifNull().failWith(StatusExceptions::memberNotFound);
        }
        String email = request.getEmail().toLowerCase(Locale.ROOT);
        return accounts.find("lower(email) = ?1 or id in (select i.accountId from AccountIdentity i"
                + " where lower(i.email) = ?1 and i.emailVerified = true) order by createdAt", email).firstResult();
    }

    private Uni<Outcome<Member>> inviteAccount(Principal principal, Document doc, Account account, Role role) {
        DocumentMemberId key = new DocumentMemberId(doc.id, account.id);
        return shareable(doc, account.id).chain(() -> members.findById(key)).flatMap(row -> {
            if (account.id.equals(doc.ownerAccountId) || row != null && !Role.NONE.dbName().equals(row.role)) {
                return Uni.createFrom().failure(StatusExceptions.alreadyMember());
            }
            return setNamed(key, row, role, principal.accountId())
                    .chain(() -> person(doc, account.id, false))
                    .flatMap(member -> changed(principal, doc, List.of(account.id), member));
        });
    }

    private Uni<Outcome<Member>> invitePending(Principal principal, Document doc, String email, Role role) {
        return workspaces.restrictsSharing(doc.teamId).chain(restricted -> {
            if (restricted) {
                return Uni.createFrom().failure(StatusExceptions.teamRoleInvalid(SHARING_RESTRICTED));
            }
            return invites.findFor(doc.id, email).flatMap(existing -> {
                DocumentInvite invite = existing != null ? existing : new DocumentInvite();
                invite.role = role.dbName();
                invite.invitedBy = principal.accountId();
                if (existing != null) {
                    return Uni.createFrom().item(invite);
                }
                invite.id = UUID.randomUUID();
                invite.documentId = doc.id;
                invite.email = email;
                return invites.persist(invite);
            }).flatMap(invite -> changed(principal, doc, List.of(), ShareMessages.pending(invite)));
        });
    }

    /** Refuses sharing with an outsider when the document's workspace restricts sharing. */
    private Uni<Void> shareable(Document doc, UUID accountId) {
        return workspaces.restrictsSharing(doc.teamId).chain(restricted -> !restricted ? Uni.createFrom().voidItem()
                : teamMembers.findById(new TeamMemberId(doc.teamId, accountId)).chain(member -> member != null
                        ? Uni.createFrom().voidItem()
                        : Uni.createFrom().failure(StatusExceptions.teamRoleInvalid(SHARING_RESTRICTED))));
    }

    /** Mails the invitation to the address named, or to the invited account's, once committed. */
    private Uni<Void> mailInvite(Outcome<Member> outcome, InviteRequest request) {
        Member member = outcome.response();
        String inviter = outcome.notices().get(0).event().getMembersChanged().getActor().getDisplayName();
        return Panache.withSession(() -> (member.getPending() ? Uni.createFrom().item(member.getEmail())
                : accounts.findById(UUID.fromString(member.getAccountId())).map(account -> account.email))
                .flatMap(email -> email.isEmpty() ? Uni.createFrom().voidItem()
                        : documents.findById(outcome.documentId()).flatMap(doc -> mailer.invite(email, doc.name, inviter,
                                ShareMessages.role(request.getRole()).dbName(), doc.id, request.getMessage()))));
    }

    @Override
    public Uni<SetRoleResponse> setRole(SetRoleRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        UUID target = UUID.fromString(request.getAccountId());
        Role role = ShareMessages.role(request.getRole());
        return tx(() -> guard.require(documentId, Role.EDITOR).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> named(doc, target).flatMap(row -> {
                    Role current = Role.fromDb(row.role);
                    if (current == Role.EDITOR && role != Role.EDITOR && grant.role() != Role.OWNER) {
                        return Uni.createFrom().failure(StatusExceptions.roleInsufficient(Role.OWNER.dbName(),
                                grant.role().dbName()));
                    }
                    row.role = role.dbName();
                    return person(doc, target, false)
                            .flatMap(member -> changed(grant.principal(), doc, List.of(target), member));
                }))))
                .call(this::announce)
                .map(outcome -> SetRoleResponse.newBuilder().setMember(outcome.response()).build());
    }

    /**
     * The target's named, non-owner row: {@code MEMBER_NOT_FOUND} without a named role,
     * {@code OWNER_MUST_TRANSFER} for the owner.
     */
    private Uni<DocumentMember> named(Document doc, UUID target) {
        return members.findById(new DocumentMemberId(doc.id, target)).flatMap(row -> {
            if (isOwner(doc, target, row)) {
                return Uni.createFrom().failure(StatusExceptions.ownerMustTransfer());
            }
            if (row == null || Role.NONE.dbName().equals(row.role)) {
                return Uni.createFrom().failure(StatusExceptions.memberNotFound());
            }
            return Uni.createFrom().item(row);
        });
    }

    @Override
    public Uni<RemoveMemberResponse> removeMember(RemoveMemberRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        UUID target = UUID.fromString(request.getAccountId());
        return tx(() -> guard.require(documentId, Role.VIEWER).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> members.findById(new DocumentMemberId(documentId, target)).flatMap(row -> {
                    if (isOwner(doc, target, row)) {
                        return Uni.createFrom().failure(StatusExceptions.ownerMustTransfer());
                    }
                    if (!mayRemove(grant, target, row)) {
                        return Uni.createFrom().failure(StatusExceptions.roleInsufficient(Role.OWNER.dbName(),
                                grant.role().dbName()));
                    }
                    if (row != null) {
                        row.role = Role.NONE.dbName();
                    }
                    return person(doc, target, false).flatMap(member -> changed(grant.principal(), doc,
                            List.of(target), member.getEffectiveRole() == DocumentMessages.role(Role.NONE) ? null : member));
                }))))
                .call(this::announce)
                .map(outcome -> outcome.response() == null ? RemoveMemberResponse.getDefaultInstance()
                        : RemoveMemberResponse.newBuilder().setMember(outcome.response()).build());
    }

    /**
     * Who may remove a named role: the owner anyone's; an editor the viewers and commenters they
     * invited; anyone their own.
     */
    static boolean mayRemove(RoleGuard.Grant grant, UUID target, DocumentMember row) {
        if (grant.role() == Role.OWNER || target.equals(grant.principal().accountId())) {
            return true;
        }
        return grant.role() == Role.EDITOR && row != null && grant.principal().accountId().equals(row.addedBy)
                && !Role.fromDb(row.role).atLeast(Role.EDITOR);
    }

    // ------------------------------------------------------------------------------------ links

    @Override
    public Uni<CreateLinkResponse> createLink(CreateLinkRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        String token = token();
        Uni<String> password = request.getPassword().isEmpty() ? Uni.createFrom().nullItem()
                : LinkPasswords.hash(request.getPassword());
        return tx(() -> guard.require(documentId, Role.OWNER).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> linkAllowed(doc, request.getTeamMembersOnly()).chain(() -> password).flatMap(hash -> {
                    ShareLink link = new ShareLink();
                    link.id = UUID.randomUUID();
                    link.documentId = documentId;
                    link.tokenHash = DocumentRoles.tokenHash(token);
                    link.role = ShareMessages.role(request.getRole()).dbName();
                    link.createdBy = grant.principal().accountId();
                    link.expiresAt = request.hasExpiresAt() ? ShareMessages.instant(request.getExpiresAt()) : null;
                    link.revokeOnExpiry = request.getRevokeOnExpiry();
                    link.passwordHash = hash;
                    link.teamMembersOnly = request.getTeamMembersOnly();
                    return links.persist(link).flatMap(saved -> changed(grant.principal(), doc, List.of(),
                            ShareMessages.link(saved, 0)));
                }))))
                .call(this::announce)
                .map(outcome -> CreateLinkResponse.newBuilder().setLink(outcome.response()).setToken(token).build());
    }

    /** A link anyone outside the team could open is refused when the workspace restricts sharing. */
    private Uni<Void> linkAllowed(Document doc, boolean teamMembersOnly) {
        return workspaces.restrictsSharing(doc.teamId).chain(restricted -> restricted && !teamMembersOnly
                ? Uni.createFrom().failure(StatusExceptions.teamRoleInvalid(SHARING_RESTRICTED))
                : Uni.createFrom().voidItem());
    }

    @Override
    public Uni<UpdateLinkResponse> updateLink(UpdateLinkRequest request) {
        UUID linkId = UUID.fromString(request.getLinkId());
        Uni<String> password = !request.hasPassword() || request.getPassword().isEmpty() ? Uni.createFrom().nullItem()
                : LinkPasswords.hash(request.getPassword());
        return tx(() -> ownedLink(linkId).flatMap(owned -> {
            ShareLink link = owned.link();
            boolean teamMembersOnly = request.hasTeamMembersOnly() ? request.getTeamMembersOnly() : link.teamMembersOnly;
            return linkAllowed(owned.doc(), teamMembersOnly).chain(() -> password).flatMap(hash -> {
                if (request.hasRole()) {
                    link.role = ShareMessages.role(request.getRole()).dbName();
                }
                if (request.hasExpiresAt()) {
                    link.expiresAt = ShareMessages.instant(request.getExpiresAt());
                }
                if (request.hasRevokeOnExpiry()) {
                    link.revokeOnExpiry = request.getRevokeOnExpiry();
                }
                if (request.hasPassword()) {
                    link.passwordHash = hash;
                }
                link.teamMembersOnly = teamMembersOnly;
                return linkChanged(owned);
            });
        }))
                .call(this::announce)
                .map(outcome -> UpdateLinkResponse.newBuilder().setLink(outcome.response()).build());
    }

    @Override
    public Uni<RevokeLinkResponse> revokeLink(RevokeLinkRequest request) {
        UUID linkId = UUID.fromString(request.getLinkId());
        return tx(() -> ownedLink(linkId).flatMap(owned -> {
            if (owned.link().revokedAt == null) {
                owned.link().revokedAt = Instant.now();
            }
            return linkChanged(owned);
        }))
                .call(this::announce)
                .replaceWith(RevokeLinkResponse.getDefaultInstance());
    }

    /** A link and its document, the caller being the document's owner. */
    record OwnedLink(ShareLink link, Document doc, RoleGuard.Grant grant) {
    }

    /** The link, if it exists and the caller owns its document; {@code LINK_INVALID} for an unknown link. */
    private Uni<OwnedLink> ownedLink(UUID linkId) {
        return links.findById(linkId).onItem().ifNull().failWith(StatusExceptions::linkInvalid)
                .flatMap(link -> guard.require(link.documentId, Role.OWNER)
                        .flatMap(grant -> documents.findById(link.documentId)
                                .map(doc -> new OwnedLink(link, doc, grant))));
    }

    /** The link after a change, with a role notice to everyone who opened it. */
    private Uni<Outcome<com.villagecompute.wiretuner.docs.v1.ShareLink>> linkChanged(OwnedLink owned) {
        return users(owned.link().id).flatMap(users -> changed(owned.grant().principal(), owned.doc(), users,
                ShareMessages.link(owned.link(), users.size())));
    }

    private Uni<List<UUID>> users(UUID linkId) {
        return linkUses.getSession().chain(session -> session
                .createQuery("select u.id.accountId from ShareLinkUse u where u.id.shareLinkId = ?1 order by u.usedAt",
                        UUID.class)
                .setParameter(1, linkId)
                .getResultList());
    }

    @Override
    public Uni<ListLinksResponse> listLinks(ListLinksRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.require(documentId, Role.OWNER).flatMap(grant -> links.getSession().chain(session -> session
                .createQuery("select l, (select count(u) from ShareLinkUse u where u.id.shareLinkId = l.id)"
                        + " from ShareLink l where l.documentId = ?1 and (?2 = true or l.revokedAt is null)"
                        + " order by l.createdAt desc, l.id", Object[].class)
                .setParameter(1, documentId)
                .setParameter(2, request.getIncludeRevoked())
                .getResultList())))
                .map(rows -> {
                    ListLinksResponse.Builder response = ListLinksResponse.newBuilder();
                    rows.forEach(row -> response.addLinks(ShareMessages.link((ShareLink) row[0], (Long) row[1])));
                    return response.build();
                });
    }

    @Override
    public Uni<OpenLinkResponse> openLink(OpenLinkRequest request) {
        String hash = DocumentRoles.tokenHash(request.getToken());
        Instant now = Instant.now();
        return tx(() -> guard.authenticated().flatMap(principal -> links.findByTokenHash(hash).flatMap(link -> {
            if (link == null || !DocumentRoles.opens(link, now)) {
                return Uni.createFrom().failure(StatusExceptions.linkInvalid());
            }
            ShareLinkUseId useId = new ShareLinkUseId(link.id, principal.accountId());
            return documents.findById(link.documentId).flatMap(doc -> linkUses.findById(useId).flatMap(used -> {
                if (used != null) {
                    return opened(principal, doc);
                }
                return passwordOk(link, request.getPassword())
                        .chain(() -> openable(doc, link, principal.accountId()))
                        .chain(() -> {
                            ShareLinkUse use = new ShareLinkUse();
                            use.id = useId;
                            return linkUses.persist(use);
                        })
                        .chain(() -> opened(principal, doc));
            }));
        })))
                .call(this::announce)
                .map(Outcome::response);
    }

    /** The link's password, when it has one: {@code LINK_PASSWORD_REQUIRED} when missing or wrong. */
    private static Uni<Void> passwordOk(ShareLink link, String password) {
        if (link.passwordHash == null) {
            return Uni.createFrom().voidItem();
        }
        return (password.isEmpty() ? Uni.createFrom().item(false) : LinkPasswords.verify(password, link.passwordHash))
                .chain(ok -> ok ? Uni.createFrom().voidItem()
                        : Uni.createFrom().failure(StatusExceptions.linkPasswordRequired()));
    }

    /**
     * A team-members-only link, or any link of a restrict-sharing workspace, opens only for members of
     * the document's team: {@code ROLE_INSUFFICIENT} otherwise.
     */
    private Uni<Void> openable(Document doc, ShareLink link, UUID accountId) {
        return workspaces.restrictsSharing(doc.teamId).chain(restricted -> {
            if (!restricted && !link.teamMembersOnly) {
                return Uni.createFrom().voidItem();
            }
            return (doc.teamId == null ? Uni.createFrom().nullItem()
                    : teamMembers.findById(new TeamMemberId(doc.teamId, accountId)))
                    .chain(member -> member != null ? Uni.createFrom().voidItem()
                            : Uni.createFrom().failure(StatusExceptions.roleInsufficient(TeamRoles.MEMBER, "none")));
        });
    }

    private Uni<Outcome<OpenLinkResponse>> opened(Principal principal, Document doc) {
        return documents.flush().chain(() -> roles.effectiveRole(doc.id, principal.accountId()))
                .flatMap(role -> changed(principal, doc, List.of(principal.accountId()), OpenLinkResponse.newBuilder()
                        .setDocumentId(doc.id.toString())
                        .setDocumentName(doc.name)
                        .setEffectiveRole(DocumentMessages.role(role))
                        .build()));
    }

    // -------------------------------------------------------------------------- access requests

    @Override
    public Uni<RequestAccessResponse> requestAccess(RequestAccessRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        return tx(() -> guard.authenticated().flatMap(principal -> documents.findById(documentId)
                .onItem().ifNull().failWith(StatusExceptions::documentNotFound)
                .flatMap(doc -> requests.findPending(documentId, principal.accountId()).flatMap(existing -> {
                    if (existing != null) {
                        return Uni.createFrom().item(new Outcome<>(existing, documentId, List.<Notice>of()));
                    }
                    AccessRequest fresh = new AccessRequest();
                    fresh.id = UUID.randomUUID();
                    fresh.documentId = documentId;
                    fresh.accountId = principal.accountId();
                    fresh.message = request.getMessage();
                    return requests.persist(fresh).flatMap(saved -> changed(principal, doc, List.of(), saved));
                }))))
                .call(this::announce)
                .call(outcome -> outcome.notices().isEmpty() ? Uni.createFrom().voidItem() : mailOwners(outcome.response()))
                .map(outcome -> RequestAccessResponse.newBuilder().setRequestId(outcome.response().id.toString()).build());
    }

    /** Mails every owner of the request's document: its owner, and for a team document the team's owners and admins. */
    private Uni<Void> mailOwners(AccessRequest request) {
        return Panache.withSession(() -> documents.findById(request.documentId)
                .flatMap(doc -> accounts.findById(request.accountId).flatMap(requester -> accounts.list(
                        "id = ?1 or id in (select m.id.accountId from DocumentMember m where m.id.documentId = ?2"
                                + " and m.role = 'owner') or id in (select t.id.accountId from TeamMember t"
                                + " where t.id.teamId = ?3 and t.role in ('owner', 'admin'))",
                        doc.ownerAccountId, doc.id, doc.teamId)
                        .flatMap(owners -> Multi.createFrom().iterable(owners)
                                .select().where(owner -> !owner.email.isEmpty())
                                .onItem().transformToUniAndConcatenate(owner -> mailer.accessRequest(owner.email, doc.name,
                                        requester.displayName, requester.email, request.message, doc.id))
                                .collect().last()))));
    }

    @Override
    public Uni<ListAccessRequestsResponse> listAccessRequests(ListAccessRequestsRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        int offset = request.getCursor().isEmpty() ? 0 : Cursors.offset(Cursors.decode(request.getCursor(), 1)[0]);
        int pageSize = Cursors.pageSize(request.getPageSize(), Cursors.SMALL_PAGE);
        return tx(() -> guard.require(documentId, Role.OWNER)
                .chain(() -> requests.listPending(documentId, offset, pageSize + 1))
                .flatMap(pending -> {
                    ListAccessRequestsResponse.Builder response = ListAccessRequestsResponse.newBuilder();
                    if (pending.size() > pageSize) {
                        response.setNextCursor(Cursors.encode(Integer.toString(offset + pageSize)));
                    }
                    return Multi.createFrom().iterable(pending.subList(0, Math.min(pending.size(), pageSize)))
                            .onItem().transformToUniAndConcatenate(r -> accounts.findById(r.accountId)
                                    .map(account -> ShareMessages.request(r, account)))
                            .collect().asList()
                            .map(found -> response.addAllRequests(found).build());
                }));
    }

    @Override
    public Uni<ResolveAccessRequestResponse> resolveAccessRequest(ResolveAccessRequestRequest request) {
        UUID requestId = UUID.fromString(request.getRequestId());
        Role grantRole = ShareMessages.role(request.getGrant());
        return tx(() -> requests.findById(requestId)
                .onItem().transform(found -> found == null || found.resolvedAt != null ? null : found)
                .onItem().ifNull().failWith(StatusExceptions::documentNotFound)
                .flatMap(pending -> guard.require(pending.documentId, Role.OWNER).flatMap(grant -> documents
                        .findById(pending.documentId).flatMap(doc -> {
                            pending.resolvedAt = Instant.now();
                            if (grantRole == Role.NONE) {
                                return changed(grant.principal(), doc, List.of(), (Member) null);
                            }
                            pending.grantedRole = grantRole.dbName();
                            DocumentMemberId key = new DocumentMemberId(doc.id, pending.accountId);
                            return members.findById(key)
                                    .chain(row -> isOwner(doc, pending.accountId, row) ? Uni.createFrom().voidItem()
                                            : setNamed(key, row, grantRole, grant.principal().accountId()))
                                    .chain(() -> person(doc, pending.accountId, false))
                                    .flatMap(member -> changed(grant.principal(), doc, List.of(pending.accountId), member));
                        })).map(outcome -> new Resolved(outcome, pending))))
                .call(resolved -> announce(resolved.outcome()))
                .call(resolved -> Panache.withSession(() -> accounts.findById(resolved.request().accountId)
                        .flatMap(requester -> documents.findById(resolved.request().documentId)
                                .flatMap(doc -> requester.email.isEmpty() ? Uni.createFrom().voidItem()
                                        : mailer.accessResolved(requester.email, doc.name,
                                                resolved.request().grantedRole == null ? "" : resolved.request().grantedRole,
                                                doc.id)))))
                .map(resolved -> resolved.outcome().response() == null ? ResolveAccessRequestResponse.getDefaultInstance()
                        : ResolveAccessRequestResponse.newBuilder().setMember(resolved.outcome().response()).build());
    }

    /** A resolved request and its outcome. */
    record Resolved(Outcome<Member> outcome, AccessRequest request) {
    }

    // ----------------------------------------------------------------------------------- owners

    @Override
    public Uni<TransferOwnershipResponse> transferOwnership(TransferOwnershipRequest request) {
        UUID documentId = UUID.fromString(request.getDocumentId());
        UUID target = UUID.fromString(request.getNewOwnerAccountId());
        return tx(() -> guard.require(documentId, Role.OWNER).flatMap(grant -> documents.findById(documentId)
                .flatMap(doc -> members.find("id.documentId = ?1 and role = 'owner'", documentId).firstResult()
                        .flatMap(ownerRow -> {
                            UUID previous = doc.teamId == null ? doc.ownerAccountId
                                    : ownerRow == null ? null : ownerRow.id.accountId();
                            if (target.equals(previous)) {
                                return transferred(grant.principal(), doc, target, previous, false);
                            }
                            return named(doc, target).flatMap(row -> transfer(grant.principal(), doc, row, ownerRow,
                                    previous));
                        }))))
                .call(this::announce)
                .map(Outcome::response);
    }

    /**
     * Makes the target the document's one owner and the previous owner an editor. A personal document
     * moves into the new owner's personal space (at its root); a team document keeps its space and
     * passes its {@code owner} row.
     */
    private Uni<Outcome<TransferOwnershipResponse>> transfer(Principal principal, Document doc, DocumentMember row,
            DocumentMember ownerRow, UUID previous) {
        UUID target = row.id.accountId();
        if (doc.teamId == null) {
            doc.ownerAccountId = target;
            doc.folderId = null;
            doc.updatedAt = Instant.now();
            row.role = Role.NONE.dbName();
            DocumentMemberId previousKey = new DocumentMemberId(doc.id, previous);
            return members.findById(previousKey)
                    .chain(existing -> setNamed(previousKey, existing, Role.EDITOR, target))
                    .chain(() -> transferred(principal, doc, target, previous, true));
        }
        // Demote first, in a flush of its own: the one-owner index must never see two owners.
        Uni<Void> demoted = Uni.createFrom().voidItem();
        if (ownerRow != null) {
            ownerRow.role = Role.EDITOR.dbName();
            demoted = members.flush();
        }
        return demoted.invoke(() -> row.role = Role.OWNER.dbName())
                .chain(() -> transferred(principal, doc, target, previous, false));
    }

    private Uni<Outcome<TransferOwnershipResponse>> transferred(Principal principal, Document doc, UUID owner,
            UUID previous, boolean moved) {
        List<UUID> affected = previous == null ? List.of(owner) : List.of(owner, previous);
        return members.flush().chain(() -> person(doc, owner, false)).flatMap(ownerMember -> {
            TransferOwnershipResponse.Builder response = TransferOwnershipResponse.newBuilder().setOwner(ownerMember);
            Uni<TransferOwnershipResponse.Builder> built = previous == null ? Uni.createFrom().item(response)
                    : person(doc, previous, false).map(response::setPreviousOwner);
            return built.flatMap(done -> changed(principal, doc, affected, done.build()));
        }).flatMap(outcome -> !moved ? Uni.createFrom().item(outcome) : Uni.createFrom().item(new Outcome<>(
                outcome.response(), outcome.documentId(), withMoved(outcome.notices(), doc, principal))));
    }

    private List<Notice> withMoved(List<Notice> notices, Document doc, Principal principal) {
        List<Notice> all = new ArrayList<>(notices);
        Participant actor = notices.get(0).event().getMembersChanged().getActor();
        all.add(new Notice(null, DocumentEvent.newBuilder().setMoved(Moved.newBuilder()
                .setSpaceId(doc.ownerAccountId.toString()).setActor(actor)).build()));
        return all;
    }

    // ---------------------------------------------------------------------------------- helpers

    /** Gives the account a named role, raising a color-only row or adding one. */
    private Uni<Void> setNamed(DocumentMemberId key, DocumentMember row, Role role, UUID addedBy) {
        if (row != null) {
            row.role = role.dbName();
            row.addedBy = addedBy;
            return Uni.createFrom().voidItem();
        }
        DocumentMember fresh = new DocumentMember();
        fresh.id = key;
        fresh.role = role.dbName();
        fresh.addedBy = addedBy;
        return members.persist(fresh).replaceWithVoid();
    }

    /**
     * The outcome of a change to the document's sharing: {@code MembersChanged} for everyone, and for
     * each affected account its new effective role ({@code AccessRemoved} when it has none left).
     */
    private <T> Uni<Outcome<T>> changed(Principal principal, Document doc, List<UUID> affected, T response) {
        return documents.flush().chain(() -> events.event(principal.accountId(), actor -> DocumentEvent.newBuilder()
                        .setMembersChanged(MembersChanged.newBuilder().setActor(actor)).build()))
                .flatMap(everyone -> Multi.createFrom().iterable(affected)
                        .onItem().transformToUniAndConcatenate(account -> roles.effectiveRole(doc.id, account)
                                .map(role -> new Notice(account, roleEvent(role, everyone.getMembersChanged().getActor()))))
                        .collect().asList()
                        .map(personal -> {
                            List<Notice> notices = new ArrayList<>();
                            notices.add(new Notice(null, everyone));
                            notices.addAll(personal);
                            return new Outcome<>(response, doc.id, notices);
                        }));
    }

    static DocumentEvent roleEvent(Role role, Participant actor) {
        if (role == Role.NONE) {
            return DocumentEvent.newBuilder().setAccessRemoved(AccessRemoved.newBuilder().setActor(actor)).build();
        }
        return DocumentEvent.newBuilder().setRoleChanged(RoleChanged.newBuilder()
                .setRole(DocumentMessages.role(role)).setActor(actor)).build();
    }

    /** Tells the document's sessions, once committed, and forgets this node's push decisions for it. */
    private Uni<Void> announce(Outcome<?> outcome) {
        grants.forget(outcome.documentId());
        return Multi.createFrom().iterable(outcome.notices())
                .onItem().transformToUniAndConcatenate(notice -> notice.audience() == null
                        ? events.publish(outcome.documentId(), notice.event())
                        : events.publishTo(outcome.documentId(), notice.audience(), notice.event()))
                .collect().last()
                .replaceWithVoid();
    }

    static String token() {
        byte[] bytes = new byte[TOKEN_BYTES];
        RANDOM.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private static <T> Uni<T> tx(Supplier<Uni<T>> work) {
        return Panache.withTransaction(work);
    }
}
