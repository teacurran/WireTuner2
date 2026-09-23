package com.villagecompute.wiretuner.api.library;

import java.util.UUID;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.auth.WorkspacePolicy;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.team.TeamRoles;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/** Who may use a team's libraries: its members above guest (COLLAB-012, COLOR-020). */
@ApplicationScoped
public class TeamMembership {

    @Inject
    WorkspacePolicy workspaces;

    @Inject
    TeamMemberRepository teamMembers;

    /**
     * The caller's membership of the team, above guest: {@code TEAM_NOT_FOUND} for an outsider,
     * {@code ROLE_INSUFFICIENT} for a guest; a workspace that requires SSO holds members to it.
     */
    public Uni<Void> require(Principal principal, UUID teamId) {
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
}
