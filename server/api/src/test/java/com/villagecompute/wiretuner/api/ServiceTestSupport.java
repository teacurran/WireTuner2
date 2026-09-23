package com.villagecompute.wiretuner.api;

import static org.assertj.core.api.Assertions.assertThat;

import java.security.SecureRandom;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import javax.sql.DataSource;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.doc.v1.Change;
import com.villagecompute.wiretuner.doc.v1.Noop;
import com.villagecompute.wiretuner.doc.v1.Op;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;

import jakarta.inject.Inject;

/**
 * Shared plumbing for the service tests: direct SQL for set-up the services under test do not
 * own (explicit shares, link uses, search records, compaction), UUIDv7 ids, minimal valid changes,
 * and assertions on the WireTuner error shape.
 */
public abstract class ServiceTestSupport {

    private static final SecureRandom RANDOM = new SecureRandom();

    @Inject
    protected DataSource dataSource;

    /** A UUIDv7: 48 bits of milliseconds, version 7, the RFC 4122 variant, random elsewhere. */
    public static UUID uuid7() {
        long msb = (System.currentTimeMillis() << 16) | 0x7000L | (RANDOM.nextLong() & 0x0fffL);
        long lsb = (RANDOM.nextLong() & 0x3fffffffffffffffL) | 0x8000000000000000L;
        return new UUID(msb, lsb);
    }

    /** A valid change of one no-op. */
    public static Change change(long replica, long seq, String label) {
        return Change.newBuilder()
                .setReplica(replica)
                .setSeq(seq)
                .setStartCounter(seq)
                .setWallTimeMs(1)
                .setLabel(label)
                .addOps(Op.newBuilder().setNoop(Noop.getDefaultInstance()))
                .build();
    }

    public static long replicaId() {
        return RANDOM.nextLong(1, Long.MAX_VALUE);
    }

    /** Runs the call and returns the status error it must fail with. */
    public static StatusRuntimeException failure(Runnable call) {
        try {
            call.run();
        } catch (StatusRuntimeException e) {
            return e;
        }
        throw new AssertionError("the call succeeded");
    }

    /** Asserts the call fails with the code and WireTuner reason. */
    public static void assertFails(Runnable call, Status.Code code, String reason) {
        StatusRuntimeException e = failure(call);
        assertThat(e.getStatus().getCode()).as(e.getStatus().getDescription()).isEqualTo(code);
        assertThat(StatusExceptions.reasonOf(e)).as(e.getStatus().getDescription()).contains(reason);
    }

    protected int exec(String sql, Object... args) {
        try (Connection c = dataSource.getConnection(); PreparedStatement s = c.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                s.setObject(i + 1, args[i]);
            }
            return s.executeUpdate();
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    protected List<Object> column(String sql, Object... args) {
        try (Connection c = dataSource.getConnection(); PreparedStatement s = c.prepareStatement(sql)) {
            for (int i = 0; i < args.length; i++) {
                s.setObject(i + 1, args[i]);
            }
            List<Object> values = new ArrayList<>();
            try (ResultSet rs = s.executeQuery()) {
                while (rs.next()) {
                    values.add(rs.getObject(1));
                }
            }
            return values;
        } catch (SQLException e) {
            throw new IllegalStateException(e);
        }
    }

    protected Object value(String sql, Object... args) {
        List<Object> values = column(sql, args);
        return values.isEmpty() ? null : values.get(0);
    }

    protected long count(String sql, Object... args) {
        return ((Number) value(sql, args)).longValue();
    }

    /** An explicit document role, as ShareService (SRV-010) will write it. */
    protected void share(UUID document, UUID account, String role) {
        exec("INSERT INTO document_member (document_id, account_id, role) VALUES (?, ?, ?)"
                + " ON CONFLICT (document_id, account_id) DO UPDATE SET role = EXCLUDED.role", document, account, role);
    }

    /** A team row with the owner as its owner member; returns its id. */
    protected UUID team(UUID owner, String defaultRole) {
        UUID id = UUID.randomUUID();
        exec("INSERT INTO team (id, name, slug, owner_account_id, default_document_role) VALUES (?, ?, ?, ?, ?)",
                id, "Team " + id, "t-" + id, owner, defaultRole);
        teamMember(id, owner, "owner");
        return id;
    }

    protected void teamMember(UUID team, UUID account, String role) {
        exec("INSERT INTO team_member (team_id, account_id, role) VALUES (?, ?, ?)", team, account, role);
    }
}
