package com.villagecompute.wiretuner.api.data;

import java.nio.charset.StandardCharsets;
import java.util.UUID;

import com.villagecompute.wiretuner.api.persistence.Document;

/**
 * Where credentials, permitted hosts and audit rows live (data-merge.adoc, Server state): a team, or
 * one account's personal space. Exactly one of the two ids is set. A document's scope is its team,
 * or its owner's account for a personal document.
 */
public record DataScope(UUID teamId, UUID accountId) {

    public static DataScope team(UUID teamId) {
        return new DataScope(teamId, null);
    }

    public static DataScope account(UUID accountId) {
        return new DataScope(null, accountId);
    }

    public static DataScope of(Document document) {
        return new DataScope(document.teamId, document.teamId == null ? document.ownerAccountId : null);
    }

    public boolean isTeam() {
        return teamId != null;
    }

    /** The scope's id, whichever it is. */
    public UUID id() {
        return isTeam() ? teamId : accountId;
    }

    /** The column that holds the scope in data_credential and data_allowed_host. */
    String column() {
        return isTeam() ? "team_id" : "account_id";
    }

    /** {@code team:<id>} or {@code account:<id>}: the envelope's associated data and cache keys start with it. */
    public String key() {
        return (isTeam() ? "team:" : "account:") + id();
    }

    /** The associated data sealing a credential's secret to this scope and name. */
    byte[] aad(String name) {
        return ("wt-data-credential\u0000" + key() + "\u0000" + name).getBytes(StandardCharsets.UTF_8);
    }
}
