package com.villagecompute.wiretuner.api.team;

import java.util.List;

import com.villagecompute.wiretuner.account.v1.TeamRole;

/**
 * Team roles as stored in {@code team_member.role} (docs/spec/security.adoc, Teams), ordered
 * owner > admin > member > guest, and their {@code TeamRole} wire form.
 */
public final class TeamRoles {

    public static final String OWNER = "owner";
    public static final String ADMIN = "admin";
    public static final String MEMBER = "member";
    public static final String GUEST = "guest";

    /** Weakest first, so a role's index is its rank. */
    static final List<String> ORDER = List.of(GUEST, MEMBER, ADMIN, OWNER);

    private TeamRoles() {
    }

    /** True when {@code role} is {@code minimum} or stronger. */
    public static boolean atLeast(String role, String minimum) {
        return ORDER.indexOf(role) >= ORDER.indexOf(minimum);
    }

    public static TeamRole toProto(String role) {
        return switch (role) {
            case OWNER -> TeamRole.TEAM_ROLE_OWNER;
            case ADMIN -> TeamRole.TEAM_ROLE_ADMIN;
            case MEMBER -> TeamRole.TEAM_ROLE_MEMBER;
            default -> TeamRole.TEAM_ROLE_GUEST;
        };
    }

    /** The stored form of a role the request's validation already restricted to admin, member or guest. */
    public static String fromProto(TeamRole role) {
        return switch (role) {
            case TEAM_ROLE_ADMIN -> ADMIN;
            case TEAM_ROLE_MEMBER -> MEMBER;
            default -> GUEST;
        };
    }
}
