package com.villagecompute.wiretuner.api.docs;

import java.util.UUID;
import java.util.function.Supplier;

import com.villagecompute.wiretuner.api.auth.Principal;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Folder;
import com.villagecompute.wiretuner.api.persistence.FolderRepository;
import com.villagecompute.wiretuner.api.persistence.TeamMemberId;
import com.villagecompute.wiretuner.api.persistence.TeamMemberRepository;
import com.villagecompute.wiretuner.api.persistence.TeamRepository;
import com.villagecompute.wiretuner.api.team.TeamRoles;

import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;

/**
 * Space access for the library (docs/spec/security.adoc, Teams): a space is the caller's own
 * account or a team. Any member of a team -- a guest included -- may list and search it (and sees
 * only the documents they can open); creating documents and folders in it needs team member or
 * above on a live team. A space the caller does not belong to is {@code SPACE_NOT_FOUND}, so
 * existence is never revealed.
 */
@ApplicationScoped
public class Spaces {

    /** A space the caller belongs to; {@code teamRole} is null for the caller's personal space. */
    public record Space(UUID id, boolean team, String teamRole, boolean teamDeleted) {

        /** May the caller create documents and folders here? */
        public boolean creatable() {
            return !team || (!teamDeleted && TeamRoles.atLeast(teamRole, TeamRoles.MEMBER));
        }
    }

    @Inject
    TeamMemberRepository teamMembers;

    @Inject
    TeamRepository teams;

    @Inject
    FolderRepository folders;

    /** The space, if the caller belongs to it; {@code SPACE_NOT_FOUND} otherwise. */
    public Uni<Space> member(Principal principal, UUID spaceId) {
        return member(principal, spaceId, StatusExceptions::spaceNotFound);
    }

    /** As {@link #member(Principal, UUID)}, failing with {@code notFound} instead. */
    public Uni<Space> member(Principal principal, UUID spaceId, Supplier<RuntimeException> notFound) {
        if (principal.accountId().equals(spaceId)) {
            return Uni.createFrom().item(new Space(spaceId, false, null, false));
        }
        return teamMembers.findById(new TeamMemberId(spaceId, principal.accountId())).flatMap(member -> {
            if (member == null) {
                return Uni.createFrom().failure(notFound.get());
            }
            return teams.findById(spaceId).map(team -> new Space(spaceId, true, member.role, team.deletedAt != null));
        });
    }

    /** The space, if the caller may create in it: {@code ROLE_INSUFFICIENT} for a guest, not found otherwise. */
    public Uni<Space> creatable(Principal principal, UUID spaceId) {
        return creatable(principal, spaceId, StatusExceptions::spaceNotFound);
    }

    /** As {@link #creatable(Principal, UUID)}, failing with {@code notFound} instead of {@code SPACE_NOT_FOUND}. */
    public Uni<Space> creatable(Principal principal, UUID spaceId, Supplier<RuntimeException> notFound) {
        return member(principal, spaceId, notFound).flatMap(space -> {
            if (space.creatable()) {
                return Uni.createFrom().item(space);
            }
            if (space.teamDeleted()) {
                return Uni.createFrom().failure(notFound.get());
            }
            return Uni.createFrom().failure(StatusExceptions.roleInsufficient(TeamRoles.MEMBER, space.teamRole()));
        });
    }

    /** The folder, which must be in the space; null for the root. {@code FOLDER_NOT_FOUND} otherwise. */
    public Uni<Folder> folderIn(UUID folderId, UUID spaceId) {
        if (folderId == null) {
            return Uni.createFrom().nullItem();
        }
        return folders.findById(folderId).flatMap(folder -> folder != null && spaceId.equals(spaceOf(folder))
                ? Uni.createFrom().item(folder)
                : Uni.createFrom().failure(StatusExceptions.folderNotFound()));
    }

    public static UUID spaceOf(Folder folder) {
        return folder.teamId == null ? folder.ownerAccountId : folder.teamId;
    }
}
