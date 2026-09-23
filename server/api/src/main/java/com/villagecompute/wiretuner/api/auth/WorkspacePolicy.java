package com.villagecompute.wiretuner.api.auth;

import java.util.Objects;
import java.util.UUID;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.Workspace;
import com.villagecompute.wiretuner.api.persistence.WorkspaceRepository;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * The workspace switches that apply on every call (SEC-002; docs/spec/security.adoc, Teams and
 * Tokens and transport). Require-SSO: a member of a workspace-bound team (owner, admin or member; a
 * guest is outside the company) reaches the team's documents and its library space only from a
 * session whose {@code wt_auth_method} is {@code sso:<the workspace's alias>}; anything else is
 * {@code FAILED_PRECONDITION / SSO_REQUIRED}. TeamService itself stays reachable, so an admin can
 * always turn the switch off again. Restrict-sharing is read by ShareService through
 * {@link #restrictsSharing}.
 */
@ApplicationScoped
public class WorkspacePolicy {

    static final String GUEST = "guest";

    @Inject
    WorkspaceRepository workspaces;

    @Inject
    TeamMemberRepository teamMembers;

    @Inject
    DocumentRepository documents;

    /** Require-SSO for the team of the document, if it is a team document. */
    public Uni<Void> requireSsoOnDocument(Principal principal, UUID documentId) {
        return documents.findById(documentId).chain(doc -> requireSso(principal, doc.teamId));
    }

    /** Require-SSO for the team; nothing for a personal space ({@code teamId} null). */
    public Uni<Void> requireSso(Principal principal, UUID teamId) {
        if (teamId == null) {
            return Uni.createFrom().voidItem();
        }
        return workspaces.findById(teamId).chain(workspace -> {
            if (workspace == null || !workspace.requireSso || satisfies(principal, workspace)) {
                return Uni.createFrom().voidItem();
            }
            return teamMembers.findById(new TeamMemberId(teamId, principal.accountId())).chain(member ->
                    member == null || GUEST.equals(member.role) ? Uni.createFrom().voidItem()
                            : Uni.createFrom().failure(StatusExceptions.ssoRequired(
                                    Objects.toString(workspace.ssoIdpAlias, ""))));
        });
    }

    /** Whether the team's workspace restricts sharing to team members; false without a workspace. */
    public Uni<Boolean> restrictsSharing(UUID teamId) {
        if (teamId == null) {
            return Uni.createFrom().item(false);
        }
        return workspaces.findById(teamId).map(workspace -> workspace != null && workspace.restrictSharing);
    }

    /** Whether the session signed in through the workspace's own SSO connection. */
    public static boolean satisfies(Principal principal, Workspace workspace) {
        return (AuthMethods.SSO_PREFIX + workspace.ssoIdpAlias).equals(principal.authMethod());
    }
}
