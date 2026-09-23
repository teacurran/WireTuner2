package com.villagecompute.wiretuner.api.data;

import java.util.List;
import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.Role;
import com.villagecompute.wiretuner.api.auth.RoleGuard;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.DocumentRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;
import com.villagecompute.wiretuner.api.team.TeamRoles;
import com.villagecompute.wiretuner.data.v1.Scope;

import io.smallrye.mutiny.Uni;
import io.vertx.mutiny.sqlclient.Pool;
import io.vertx.mutiny.sqlclient.Row;
import io.vertx.mutiny.sqlclient.Tuple;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Who may use a data scope (data-merge.adoc, Server; D-062). Managing -- credentials, permitted hosts,
 * the audit trail -- is for the team's admins and owner in a team scope, and for the account itself
 * in its personal scope. Reading the names of credentials and hosts is for any member of the team
 * (a guest included), the account itself, or an editor of a document of the scope. Fetching is for an
 * editor of the document, in the document's scope. Run inside the call's reactive session.
 */
@ApplicationScoped
public class Scopes {

    /** A caller cleared for a scope. */
    public record Caller(Principal principal, DataScope scope) {

        public UUID accountId() {
            return principal.accountId();
        }
    }

    @Inject
    RoleGuard guard;

    @Inject
    TeamMemberRepository teamMembers;

    @Inject
    TeamRepository teams;

    @Inject
    DocumentRepository documents;

    @Inject
    Pool pool;

    /** Credentials, hosts and audit: team admin or owner, or the account itself. */
    public Uni<Caller> manage(Scope scope) {
        return resolve(scope, TeamRoles.ADMIN);
    }

    /** Names of credentials and hosts: any team member, or the account itself. */
    public Uni<Caller> read(Scope scope) {
        return resolve(scope, TeamRoles.GUEST);
    }

    /** An editor of the document, in the document's scope. */
    public Uni<Caller> document(UUID documentId) {
        return guard.require(documentId, Role.EDITOR)
                .chain(grant -> documents.findById(documentId).map(document -> new Caller(grant.principal(),
                        DataScope.of(document))));
    }

    private Uni<Caller> resolve(Scope scope, String minimum) {
        return guard.authenticated().chain(principal -> {
            if (scope.hasAccountId()) {
                UUID account = UUID.fromString(scope.getAccountId());
                if (!account.equals(principal.accountId())) {
                    return Uni.createFrom().failure(StatusExceptions.spaceNotFound());
                }
                return Uni.createFrom().item(new Caller(principal, DataScope.account(account)));
            }
            UUID team = UUID.fromString(scope.getTeamId());
            return teamMembers.findById(new TeamMemberId(team, principal.accountId())).chain(member -> {
                if (member == null) {
                    return Uni.createFrom().failure(StatusExceptions.teamNotFound());
                }
                return teams.findById(team).chain(row -> {
                    if (row.deletedAt != null) {
                        return Uni.createFrom().failure(StatusExceptions.teamNotFound());
                    }
                    if (!TeamRoles.atLeast(member.role, minimum)) {
                        return Uni.createFrom().failure(StatusExceptions.roleInsufficient(minimum, member.role));
                    }
                    return Uni.createFrom().item(new Caller(principal, DataScope.team(team)));
                });
            });
        });
    }

    /** The display names (else emails) of the team's owner and admins, for HOST_NOT_ALLOWED. */
    public Uni<String> adminNames(UUID team) {
        return pool.preparedQuery("SELECT coalesce(nullif(a.display_name, ''), a.email) AS name FROM team_member m"
                + " JOIN account a ON a.id = m.account_id WHERE m.team_id = $1 AND m.role IN ('owner', 'admin') ORDER BY 1")
                .execute(Tuple.of(team))
                .map(rows -> {
                    List<String> names = new java.util.ArrayList<>();
                    for (Row row : rows) {
                        names.add(row.getString("name"));
                    }
                    return String.join(", ", names);
                });
    }
}
