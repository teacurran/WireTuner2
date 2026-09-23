package com.villagecompute.wiretuner.api.auth;

import java.util.UUID;

import org.jboss.logging.Logger;

import io.quarkus.hibernate.reactive.panache.Panache;
import io.smallrye.mutiny.Uni;

import jakarta.enterprise.context.ApplicationScoped;

/**
 * What a sign-in does besides recording the principal (SEC-002, SRV-010), run on the request's
 * session whenever {@link Principals} sees a sign-in: a new account, a newly linked identity, or a
 * Mac it has not seen for the account.
 *
 * <ul>
 * <li><b>Auto-admit.</b> The account joins, as a member, every live team whose workspace auto-admits
 * and has verified the domain of one of the account's identities whose provider asserted the address
 * verified. Apple private relay addresses never count. A workspace that requires SSO admits only a
 * session signed in through its connection.</li>
 * <li><b>Pending invitations.</b> Invitations to documents by an address one of the account's verified
 * identities holds become named roles (a color-only row is raised to the invited role).</li>
 * </ul>
 */
@ApplicationScoped
public class SignInEffects {

    private static final Logger LOG = Logger.getLogger(SignInEffects.class);

    static final String ADMIT = """
            INSERT INTO team_member (team_id, account_id, role)
            SELECT DISTINCT w.team_id, CAST(?1 AS uuid), 'member'
            FROM workspace w
            JOIN team t ON t.id = w.team_id AND t.deleted_at IS NULL
            JOIN workspace_domain d ON d.team_id = w.team_id AND d.verified_at IS NOT NULL
            JOIN account_identity i ON i.account_id = ?1 AND i.email_verified AND NOT i.is_relay
                 AND lower(split_part(i.email, '@', 2)) = d.domain
            WHERE w.auto_admit AND (NOT w.require_sso OR ?2 = 'sso:' || w.sso_idp_alias)
            ON CONFLICT (team_id, account_id) DO NOTHING
            """;

    static final String VERIFIED_EMAILS = """
            SELECT lower(i.email) FROM account_identity i WHERE i.account_id = ?1 AND i.email_verified AND i.email <> ''
            """;

    static final String BIND = """
            INSERT INTO document_member AS m (document_id, account_id, role, added_by)
            SELECT v.document_id, CAST(?1 AS uuid), v.role, v.invited_by FROM document_invite v
            WHERE lower(v.email) IN (""" + VERIFIED_EMAILS + """
            )
            ON CONFLICT (document_id, account_id) DO UPDATE SET role = EXCLUDED.role, added_by = EXCLUDED.added_by
                WHERE m.role = 'none'
            """;

    static final String BOUND = "DELETE FROM document_invite WHERE lower(email) IN (" + VERIFIED_EMAILS + ")";

    /** Applies the effects for the account signing in by {@code authMethod}. */
    public Uni<Void> apply(UUID accountId, String authMethod) {
        return Panache.getSession().chain(session -> session.flush()
                .chain(() -> session.createNativeQuery(ADMIT).setParameter(1, accountId).setParameter(2, authMethod)
                        .executeUpdate())
                .invoke(admitted -> LOG.debugf("sign-in of %s auto-admitted it to %d team(s)", accountId, admitted))
                .chain(() -> session.createNativeQuery(BIND).setParameter(1, accountId).executeUpdate())
                .chain(() -> session.createNativeQuery(BOUND).setParameter(1, accountId).executeUpdate()))
                .replaceWithVoid();
    }
}
