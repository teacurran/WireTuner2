package com.villagecompute.wiretuner.api.auth;

/**
 * A principal's effective role on one document (docs/spec/security.adoc, Document roles), ordered
 * so that {@link #atLeast} is a plain comparison. {@link #NONE} is "no access" and is never stored.
 */
public enum Role {
    NONE("none"),
    VIEWER("viewer"),
    COMMENTER("commenter"),
    EDITOR("editor"),
    OWNER("owner");

    private final String dbName;

    Role(String dbName) {
        this.dbName = dbName;
    }

    /** The value stored in {@code document_member.role}, {@code share_link.role} and {@code team.default_document_role}. */
    public String dbName() {
        return dbName;
    }

    /** The role a stored value names; the schema's CHECK constraints keep the set closed. */
    public static Role fromDb(String value) {
        for (Role role : values()) {
            if (role.dbName.equals(value)) {
                return role;
            }
        }
        throw new IllegalArgumentException("unknown document role: " + value);
    }

    public boolean atLeast(Role minimum) {
        return ordinal() >= minimum.ordinal();
    }

    public static Role max(Role a, Role b) {
        return a.ordinal() >= b.ordinal() ? a : b;
    }
}
