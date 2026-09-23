package com.villagecompute.wiretuner.api.persistence;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import javax.sql.DataSource;

import org.flywaydb.core.Flyway;
import org.junit.jupiter.api.Test;

import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * SRV-003: the migrations apply from empty on Postgres 17 (Dev Services), every table exists, and
 * the constraints the services rely on hold: document space XOR, change_log hash partitioning with
 * its (document_id, server_seq) primary key, one owner per document.
 */
@QuarkusTest
class SchemaTest {

    static final List<String> TABLES = List.of("account", "account_identity", "device", "team", "team_member",
            "team_invite", "workspace", "workspace_domain", "document", "document_member", "share_link",
            "share_link_use", "branch", "version", "document_search", "replica", "change_log", "snapshot",
            "cold_segment", "blob", "document_blob", "folder", "document_invite", "access_request", "data_credential",
            "data_allowed_host", "data_fetch_audit", "library", "comment_thread", "comment", "comment_read",
            "comment_notification", "publish", "publish_file", "change_node", "node_name", "history_backfill");

    @Inject
    Flyway flyway;

    @Inject
    DataSource dataSource;

    @Test
    void flywayReachedV12() {
        assertThat(flyway.info().current().getVersion().getVersion()).isEqualTo("12");
        assertThat(flyway.info().pending()).isEmpty();
    }

    @Test
    void everyTableExists() throws SQLException {
        List<String> present = strings("SELECT tablename FROM pg_tables WHERE schemaname = 'public'");
        assertThat(present).containsAll(TABLES);
        assertThat(strings("SELECT extname FROM pg_extension")).contains("pg_trgm");
        assertThat(strings("SELECT value FROM schema_info WHERE key = 'wiretuner.schema'")).containsExactly("COLLAB-020");
    }

    @Test
    void changeLogHasSixteenHashPartitions() throws SQLException {
        List<String> partitions = strings("""
                SELECT c.relname FROM pg_inherits i JOIN pg_class c ON c.oid = i.inhrelid
                WHERE i.inhparent = 'change_log'::regclass ORDER BY c.relname""");
        assertThat(partitions).hasSize(16).first().isEqualTo("change_log_p00");
        assertThat(strings("SELECT partstrat::text FROM pg_partitioned_table WHERE partrelid = 'change_log'::regclass"))
                .containsExactly("h");
    }

    @Test
    void documentSpaceIsAccountXorTeam() throws SQLException {
        UUID account = account();
        UUID team = team(account);
        exec("INSERT INTO document (id, owner_account_id) VALUES ('" + UUID.randomUUID() + "', '" + account + "')");
        exec("INSERT INTO document (id, team_id) VALUES ('" + UUID.randomUUID() + "', '" + team + "')");

        assertThatThrownBy(() -> exec("INSERT INTO document (id, owner_account_id, team_id) VALUES ('"
                + UUID.randomUUID() + "', '" + account + "', '" + team + "')"))
                .hasMessageContaining("document_space_xor");
        assertThatThrownBy(() -> exec("INSERT INTO document (id) VALUES ('" + UUID.randomUUID() + "')"))
                .hasMessageContaining("document_space_xor");
    }

    @Test
    void changeLogRowsRouteToPartitionsAndKeyIsUnique() throws SQLException {
        UUID account = account();
        List<String> partitions = new ArrayList<>();
        UUID first = null;
        for (int i = 0; i < 2; i++) {
            UUID doc = UUID.randomUUID();
            first = first == null ? doc : first;
            exec("INSERT INTO document (id, owner_account_id) VALUES ('" + doc + "', '" + account + "')");
            exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size) VALUES ('"
                    + doc + "', 1, 7, 1, '\\x01', 1)");
            partitions.addAll(strings("SELECT tableoid::regclass::text FROM change_log WHERE document_id = '" + doc + "'"));
        }
        assertThat(partitions).hasSize(2).allMatch(p -> p.matches("change_log_p\\d\\d"));
        // The partition is a function of the document id alone.
        assertThat(strings("SELECT tableoid::regclass::text FROM change_log WHERE document_id = '" + first + "'"))
                .containsExactly(partitions.get(0));

        UUID dup = first;
        assertThatThrownBy(() -> exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size)"
                + " VALUES ('" + dup + "', 1, 8, 1, '\\x02', 1)"))
                .hasMessageContaining("duplicate key");
        assertThatThrownBy(() -> exec("INSERT INTO change_log (document_id, server_seq, replica_id, seq, bytes, byte_size)"
                + " VALUES ('" + dup + "', 2, 7, 1, '\\x02', 1)"))
                .hasMessageContaining("duplicate key");
    }

    @Test
    void aDocumentHasOneOwnerRow() throws SQLException {
        UUID a = account();
        UUID b = account();
        UUID team = team(a);
        UUID doc = UUID.randomUUID();
        exec("INSERT INTO document (id, team_id) VALUES ('" + doc + "', '" + team + "')");
        exec("INSERT INTO document_member (document_id, account_id, role) VALUES ('" + doc + "', '" + a + "', 'owner')");
        assertThatThrownBy(() -> exec("INSERT INTO document_member (document_id, account_id, role) VALUES ('"
                + doc + "', '" + b + "', 'owner')")).hasMessageContaining("document_member_one_owner");
    }

    UUID account() throws SQLException {
        UUID id = UUID.randomUUID();
        exec("INSERT INTO account (id, subject) VALUES ('" + id + "', 'schema-" + id + "')");
        return id;
    }

    UUID team(UUID owner) throws SQLException {
        UUID id = UUID.randomUUID();
        exec("INSERT INTO team (id, name, slug, owner_account_id) VALUES ('" + id + "', 'T', 't-" + id + "', '" + owner + "')");
        return id;
    }

    void exec(String sql) throws SQLException {
        try (Connection c = dataSource.getConnection(); Statement s = c.createStatement()) {
            s.execute(sql);
        }
    }

    List<String> strings(String sql) throws SQLException {
        List<String> out = new ArrayList<>();
        try (Connection c = dataSource.getConnection(); Statement s = c.createStatement(); ResultSet rs = s.executeQuery(sql)) {
            while (rs.next()) {
                out.add(rs.getString(1));
            }
        }
        return out;
    }
}
