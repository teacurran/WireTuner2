package com.villagecompute.wiretuner.api.auth;

import java.util.UUID;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.observability.RateLimiter;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * What every RPC calls before touching a document: resolves the caller and checks its effective
 * role against the minimum the RPC needs. {@code NONE} is {@code NOT_FOUND / DOCUMENT_NOT_FOUND}
 * (deleted and never-visible are indistinguishable on purpose); a role below the minimum is
 * {@code PERMISSION_DENIED / ROLE_INSUFFICIENT}; no valid token is {@code UNAUTHENTICATED}, with
 * {@code TOKEN_EXPIRED} when a refresh would help (docs/spec/api-conventions.adoc, Errors); an
 * exhausted rate limit is {@code RESOURCE_EXHAUSTED / RATE_LIMITED} (SRV-014); a password session of
 * a member of an SSO-required workspace is {@code SSO_REQUIRED} on the team's documents (SEC-002).
 */
@ApplicationScoped
public class RoleGuard {

    /** A passed check: who called and what they hold on the document. */
    public record Grant(Principal principal, Role role) {
    }

    @Inject
    Principals principals;

    @Inject
    DocumentRoles documentRoles;

    @Inject
    RateLimiter limits;

    @Inject
    WorkspacePolicy workspaces;

    /** For RPCs that need a signed-in caller and nothing else ({@code AccountService.Me}); rate-limited per account. */
    public Uni<Principal> authenticated() {
        return principals.current().call(principal -> limits.check(principal.accountId(), null, 1));
    }

    /** Resolves the caller, then {@link #require(Principal, UUID, Role)}. */
    public Uni<Grant> require(UUID documentId, Role minimum) {
        return principals.current().flatMap(principal -> require(principal, documentId, minimum));
    }

    /**
     * Checks an already-resolved caller's role on the document: the account's and the document's rate
     * limits first, then the role, then the team workspace's require-SSO rule.
     */
    public Uni<Grant> require(Principal principal, UUID documentId, Role minimum) {
        return limits.check(principal.accountId(), documentId, 1)
                .chain(() -> documentRoles.effectiveRole(documentId, principal.accountId()))
                .flatMap(role -> {
                    if (role == Role.NONE) {
                        return Uni.createFrom().failure(StatusExceptions.documentNotFound());
                    }
                    if (!role.atLeast(minimum)) {
                        return Uni.createFrom().failure(StatusExceptions.roleInsufficient(minimum.dbName(), role.dbName()));
                    }
                    return workspaces.requireSsoOnDocument(principal, documentId).replaceWith(new Grant(principal, role));
                });
    }
}
