package com.villagecompute.wiretuner.api.team;

import static org.assertj.core.api.Assertions.assertThat;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.DnsStub;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.jobs.JobLocks;

import io.quarkus.test.junit.QuarkusTest;
import io.quarkus.vertx.VertxContextSupport;
import io.smallrye.mutiny.Uni;

import jakarta.inject.Inject;

/**
 * SEC-002: the hourly Domains job re-verifies workspace domains through the DNS stub: a claimed
 * domain whose record appears becomes verified (unless another team holds it), a verified one whose
 * record disappears keeps its verification for two misses and loses it at the third, and a node that
 * cannot take the job's advisory lock skips the run.
 */
@QuarkusTest
class DomainJobTest extends ServiceTestSupport {

    @Inject
    DomainJob job;

    @Inject
    JobLocks locks;

    static <T> T run(java.util.function.Supplier<Uni<T>> work) {
        try {
            return VertxContextSupport.subscribeAndAwait(work::get);
        } catch (Throwable t) {
            throw new IllegalStateException(t);
        }
    }

    UUID claim(String domain, String token, boolean verified) {
        UUID owner = UUID.randomUUID();
        exec("INSERT INTO account (id, subject) VALUES (?, ?)", owner, "domains-" + owner);
        UUID team = team(owner, "editor");
        exec("INSERT INTO workspace (team_id) VALUES (?)", team);
        exec("INSERT INTO workspace_domain (team_id, domain, verification_token, verified_at) VALUES (?, ?, ?, "
                + (verified ? "now()" : "NULL") + ")", team, domain, token);
        return team;
    }

    Object verifiedAt(UUID team, String domain) {
        return value("SELECT verified_at FROM workspace_domain WHERE team_id = ? AND domain = ?", team, domain);
    }

    @Test
    void recordsThatAppearVerifyAndRecordsThatVanishExpire() {
        String fresh = "f" + UUID.randomUUID().toString().substring(0, 8) + ".example";
        String held = "h" + UUID.randomUUID().toString().substring(0, 8) + ".example";
        UUID claimant = claim(fresh, "tok-fresh", false);
        UUID holder = claim(held, "tok-held", true);
        UUID rival = claim(held, "tok-rival", false);
        DnsStub.TXT.put(fresh, List.of(DomainVerifier.record("tok-fresh")));
        DnsStub.TXT.put(held, List.of(DomainVerifier.record("tok-held"), DomainVerifier.record("tok-rival")));

        assertThat(run(job::scheduled)).isNull();
        assertThat(verifiedAt(claimant, fresh)).isNotNull();
        assertThat(verifiedAt(holder, held)).isNotNull();
        assertThat(verifiedAt(rival, held)).as("another team holds it").isNull();
        assertThat(value("SELECT checked_at FROM workspace_domain WHERE team_id = ?", claimant)).isNotNull();

        DnsStub.TXT.remove(held);
        run(job::reverify);
        run(job::reverify);
        assertThat(verifiedAt(holder, held)).isNotNull();
        assertThat(count("SELECT failed_checks FROM workspace_domain WHERE team_id = ?", holder)).isEqualTo(2);
        // The record is back: the count starts over.
        DnsStub.TXT.put(held, List.of(DomainVerifier.record("tok-held")));
        run(job::reverify);
        assertThat(count("SELECT failed_checks FROM workspace_domain WHERE team_id = ?", holder)).isZero();
        DnsStub.TXT.remove(held);
        run(job::reverify);
        run(job::reverify);
        run(job::reverify);
        assertThat(verifiedAt(holder, held)).isNull();
        assertThat(count("SELECT failed_checks FROM workspace_domain WHERE team_id = ?", holder)).isZero();
        DnsStub.TXT.remove(fresh);
    }

    @Test
    void aJobHeldByAnotherNodeIsSkipped() throws Exception {
        try (Connection c = dataSource.getConnection()) {
            c.setAutoCommit(false);
            try (PreparedStatement lock = c.prepareStatement("SELECT pg_advisory_xact_lock(hashtextextended(?, 0))")) {
                lock.setString(1, "job:probe");
                lock.execute();
            }
            boolean[] ran = {false};
            assertThat(run(() -> locks.exclusively("probe", () -> {
                ran[0] = true;
                return Uni.createFrom().voidItem();
            }))).isFalse();
            assertThat(ran[0]).isFalse();
            c.rollback();
        }
        assertThat(run(() -> locks.exclusively("probe", () -> Uni.createFrom().voidItem()))).isTrue();
    }
}
