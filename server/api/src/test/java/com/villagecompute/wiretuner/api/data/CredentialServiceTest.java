package com.villagecompute.wiretuner.api.data;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.List;
import java.util.logging.Handler;
import java.util.logging.LogRecord;

import org.jboss.logmanager.ExtLogRecord;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.EgressStub;
import com.villagecompute.wiretuner.api.Reactive;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.data.v1.Credential;
import com.villagecompute.wiretuner.data.v1.CredentialKind;
import com.villagecompute.wiretuner.data.v1.DeleteAllowedHostRequest;
import com.villagecompute.wiretuner.data.v1.DeleteCredentialRequest;
import com.villagecompute.wiretuner.data.v1.ListAllowedHostsRequest;
import com.villagecompute.wiretuner.data.v1.ListAllowedHostsResponse;
import com.villagecompute.wiretuner.data.v1.ListCredentialsRequest;
import com.villagecompute.wiretuner.data.v1.ListCredentialsResponse;
import com.villagecompute.wiretuner.data.v1.PutAllowedHostRequest;
import com.villagecompute.wiretuner.data.v1.PutCredentialRequest;

import io.grpc.Status;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * DATA-005 and DATA-007: the credential store and the allowlists. Each kind round-trips through a
 * fetch (the stub sees the header the kind produces); nothing any RPC returns and nothing in the
 * database holds a secret in clear; team writes are admin-only while editors fetch; other teams and
 * other accounts see nothing; key rotation rewraps every row and fetches still work; requests are
 * logged with their secrets redacted.
 */
@QuarkusTest
class CredentialServiceTest extends DataTestSupport {

    @Inject
    CredentialRotationJob rotation;

    @Inject
    CredentialRepository repository;

    @Inject
    MasterKeys keys;

    static final String SECRET = "tok-" + java.util.UUID.randomUUID();

    /** The Authorization (or named) header the stub saw on a proxy call through the credential. */
    String sentHeader(String user, java.util.UUID document, String credential, String header) {
        route("/echo", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        as(data, user).proxy(proxy(document, "/echo").setCredentialName(credential).build());
        List<EgressStub.Seen> requests = seen("/echo");
        return requests.get(requests.size() - 1).header(header);
    }

    @Test
    void everyKindProducesItsHeader() {
        allowEverywhere();
        String key = EgressStub.hostKey(host);
        as(data, BOB).putCredential(bearer(teamScope(team), "bearer", key, SECRET).build());
        as(data, BOB).putCredential(PutCredentialRequest.newBuilder().setScope(teamScope(team)).setName("basic")
                .setKind(CredentialKind.CREDENTIAL_KIND_BASIC).setHost(key.toUpperCase()).setUsername("Aladdin")
                .setPassword("open sesame").build());
        as(data, BOB).putCredential(PutCredentialRequest.newBuilder().setScope(teamScope(team)).setName("apikey")
                .setKind(CredentialKind.CREDENTIAL_KIND_HEADER).setHost(key).setHeaderName("X-Api-Token")
                .setHeaderValue("k-123").build());
        assertThat(sentHeader(CAROL, teamDoc, "bearer", "authorization")).isEqualTo("Bearer " + SECRET);
        assertThat(sentHeader(CAROL, teamDoc, "basic", "authorization")).isEqualTo("Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==");
        assertThat(sentHeader(CAROL, teamDoc, "apikey", "x-api-token")).isEqualTo("k-123");
        // The credential's own header may not also come from the request.
        assertFails(() -> as(data, CAROL).proxy(proxy(teamDoc, "/echo").setCredentialName("apikey")
                .putHeaders("X-API-TOKEN", "forged").build()), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertFails(() -> as(data, CAROL).proxy(proxy(teamDoc, "/echo").setCredentialName("nope").build()),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.CREDENTIAL_MISSING);
    }

    @Test
    void secretsNeverComeBackNorRestInClear() throws Exception {
        String key = EgressStub.hostKey(host);
        Credential stored = as(data, BOB).putCredential(bearer(teamScope(team), "gh", key, SECRET).build()).getCredential();
        assertThat(stored.getName()).isEqualTo("gh");
        assertThat(stored.getHost()).isEqualTo(key);
        assertThat(stored.getCreatedByAccountId()).isEqualTo(bob.toString());
        assertThat(stored.hasRotatedAt()).isFalse();
        assertThat(stored.toByteString().toStringUtf8()).doesNotContain(SECRET);
        ListCredentialsResponse listed = as(data, CAROL).listCredentials(ListCredentialsRequest.newBuilder()
                .setScope(teamScope(team)).build());
        assertThat(listed.getCredentialsList()).extracting(Credential::getName).containsExactly("gh");
        assertThat(listed.toByteString().toStringUtf8()).doesNotContain(SECRET).doesNotContain("tok-");
        // Replacing keeps the row and records when.
        Credential replaced = as(data, ALICE).putCredential(bearer(teamScope(team), "gh", key, SECRET + "-2").build())
                .getCredential();
        assertThat(replaced.hasRotatedAt()).isTrue();
        assertThat(replaced.getCreatedByAccountId()).isEqualTo(bob.toString());
        // A dump of the table (every column as text) holds no plaintext secret.
        StringBuilder dump = new StringBuilder();
        try (Connection c = dataSource.getConnection(); Statement s = c.createStatement();
                ResultSet rs = s.executeQuery("SELECT * FROM data_credential")) {
            int columns = rs.getMetaData().getColumnCount();
            while (rs.next()) {
                for (int i = 1; i <= columns; i++) {
                    Object value = rs.getObject(i);
                    dump.append(value instanceof byte[] bytes ? new String(bytes, StandardCharsets.ISO_8859_1) : value).append('|');
                }
            }
        }
        assertThat(dump).contains("gh").doesNotContain(SECRET).doesNotContain("tok-");
    }

    @Test
    void teamWritesAreForAdminsAndEditorsFetch() {
        allowEverywhere();
        String key = EgressStub.hostKey(host);
        assertFails(() -> as(data, CAROL).putCredential(bearer(teamScope(team), "c", key, SECRET).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> as(data, ERIN).putCredential(bearer(teamScope(team), "c", key, SECRET).build()),
                Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        as(data, BOB).putCredential(bearer(teamScope(team), "c", key, SECRET).build());
        assertThat(sentHeader(CAROL, teamDoc, "c", "authorization")).isEqualTo("Bearer " + SECRET);
        // Another team's member cannot list it; a guest of this team sees the names.
        assertFails(() -> as(data, ERIN).listCredentials(ListCredentialsRequest.newBuilder().setScope(teamScope(team)).build()),
                Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        assertThat(as(data, DAVE).listCredentials(ListCredentialsRequest.newBuilder().setScope(teamScope(team)).build())
                .getCredentialsCount()).isEqualTo(1);
        // Editors of a document read its scope's names; others cannot.
        assertThat(as(data, CAROL).listCredentials(ListCredentialsRequest.newBuilder().setDocumentId(teamDoc.toString()).build())
                .getCredentialsList()).extracting(Credential::getName).containsExactly("c");
        assertFails(() -> as(data, DAVE).listCredentials(ListCredentialsRequest.newBuilder().setDocumentId(teamDoc.toString()).build()),
                Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
        // Deleting is an admin's too.
        assertFails(() -> as(data, CAROL).deleteCredential(DeleteCredentialRequest.newBuilder().setScope(teamScope(team))
                .setName("c").build()), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertThat(as(data, BOB).deleteCredential(DeleteCredentialRequest.newBuilder().setScope(teamScope(team)).setName("c")
                .build()).getDeleted()).isTrue();
        assertThat(as(data, BOB).deleteCredential(DeleteCredentialRequest.newBuilder().setScope(teamScope(team)).setName("c")
                .build()).getDeleted()).isFalse();
        // A deleted team is gone for everyone.
        exec("UPDATE team SET deleted_at = now() WHERE id = ?", team);
        assertFails(() -> as(data, BOB).listCredentials(ListCredentialsRequest.newBuilder().setScope(teamScope(team)).build()),
                Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
    }

    @Test
    void personalCredentialsAreTheOwnersAndSharedEditorsFetchWithThem() {
        allowEverywhere();
        String key = EgressStub.hostKey(host);
        as(data, ALICE).putCredential(bearer(accountScope(alice), "mine", key, SECRET).build());
        assertFails(() -> as(data, ERIN).putCredential(bearer(accountScope(alice), "x", key, SECRET).build()),
                Status.Code.NOT_FOUND, ErrorReasons.SPACE_NOT_FOUND);
        assertFails(() -> as(data, ERIN).listCredentials(ListCredentialsRequest.newBuilder().setScope(accountScope(alice)).build()),
                Status.Code.NOT_FOUND, ErrorReasons.SPACE_NOT_FOUND);
        share(personalDoc, erin, "editor");
        assertThat(sentHeader(ERIN, personalDoc, "mine", "authorization")).isEqualTo("Bearer " + SECRET);
        share(personalDoc, erin, "viewer");
        assertFails(() -> as(data, ERIN).proxy(proxy(personalDoc, "/echo").setCredentialName("mine").build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        assertThat(as(data, ALICE).deleteCredential(DeleteCredentialRequest.newBuilder().setScope(accountScope(alice))
                .setName("mine").build()).getDeleted()).isTrue();
    }

    @Test
    void listsPage() {
        String key = EgressStub.hostKey(host);
        for (String name : List.of("c1", "c2", "c3")) {
            as(data, ALICE).putCredential(bearer(teamScope(team), name, key, SECRET).build());
        }
        exec("UPDATE data_credential SET created_by = NULL WHERE team_id = ? AND name = 'c3'", team);
        ListCredentialsResponse first = as(data, DAVE).listCredentials(ListCredentialsRequest.newBuilder().setScope(teamScope(team))
                .setPageSize(2).build());
        assertThat(first.getCredentialsList()).extracting(Credential::getName).containsExactly("c1", "c2");
        ListCredentialsResponse second = as(data, DAVE).listCredentials(ListCredentialsRequest.newBuilder().setScope(teamScope(team))
                .setPageSize(2).setCursor(first.getNextCursor()).build());
        assertThat(second.getCredentialsList()).extracting(Credential::getName).containsExactly("c3");
        assertThat(second.getCredentials(0).getCreatedByAccountId()).isEmpty();
        assertThat(second.getNextCursor()).isEmpty();
        assertFails(() -> as(data, DAVE).listCredentials(ListCredentialsRequest.newBuilder().setScope(teamScope(team))
                .setCursor("%%%").build()), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
    }

    @Test
    void allowlistsAreManagedByAdminsAndAccounts() {
        String key = EgressStub.hostKey(host);
        assertFails(() -> as(data, CAROL).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(teamScope(team)).setHost(key)
                .build()), Status.Code.PERMISSION_DENIED, ErrorReasons.ROLE_INSUFFICIENT);
        var added = as(data, BOB).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(teamScope(team))
                .setHost(key.toUpperCase()).build()).getHost();
        assertThat(added.getHost()).isEqualTo(key);
        assertThat(added.getAddedByAccountId()).isEqualTo(bob.toString());
        // Idempotent: the entry stays as first added.
        assertThat(as(data, ALICE).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(teamScope(team)).setHost(key).build())
                .getHost().getAddedByAccountId()).isEqualTo(bob.toString());
        as(data, BOB).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(teamScope(team)).setHost("api.example.com:443").build());
        as(data, BOB).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(teamScope(team)).setHost("zz.example.com").build());
        exec("UPDATE data_allowed_host SET added_by = NULL WHERE team_id = ? AND host = 'zz.example.com'", team);
        ListAllowedHostsResponse page = as(data, DAVE).listAllowedHosts(ListAllowedHostsRequest.newBuilder()
                .setScope(teamScope(team)).setPageSize(2).build());
        assertThat(page.getHostsList()).extracting(h -> h.getHost()).containsExactly("api.example.com", key);
        ListAllowedHostsResponse rest = as(data, CAROL).listAllowedHosts(ListAllowedHostsRequest.newBuilder()
                .setDocumentId(teamDoc.toString()).setPageSize(2).setCursor(page.getNextCursor()).build());
        assertThat(rest.getHostsList()).extracting(h -> h.getHost()).containsExactly("zz.example.com");
        assertThat(rest.getHosts(0).getAddedByAccountId()).isEmpty();
        assertThat(rest.getNextCursor()).isEmpty();
        // An account adds to its own list only.
        as(data, ERIN).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(accountScope(erin)).setHost(key).build());
        assertFails(() -> as(data, ERIN).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(accountScope(alice)).setHost(key)
                .build()), Status.Code.NOT_FOUND, ErrorReasons.SPACE_NOT_FOUND);
        assertThat(as(data, ERIN).listAllowedHosts(ListAllowedHostsRequest.newBuilder().setScope(accountScope(erin)).build())
                .getHostsCount()).isEqualTo(1);
        assertThat(as(data, ERIN).deleteAllowedHost(DeleteAllowedHostRequest.newBuilder().setScope(accountScope(erin))
                .setHost(key.toUpperCase()).build()).getDeleted()).isTrue();
        assertThat(as(data, ERIN).deleteAllowedHost(DeleteAllowedHostRequest.newBuilder().setScope(accountScope(erin))
                .setHost(key).build()).getDeleted()).isFalse();
        assertFails(() -> as(data, ERIN).listAllowedHosts(ListAllowedHostsRequest.newBuilder().setScope(teamScope(team)).build()),
                Status.Code.NOT_FOUND, ErrorReasons.TEAM_NOT_FOUND);
        assertFails(() -> as(data, ERIN).listAllowedHosts(ListAllowedHostsRequest.newBuilder().setScope(teamScope(team))
                .setCursor("%%%").build()), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
    }

    @Test
    void rotationRewrapsEveryRowAndFetchesStillWork() {
        allowEverywhere();
        String key = EgressStub.hostKey(host);
        // A row wrapped with the previous key "t1", as a server configured before the rotation wrote it.
        Envelope previous = Envelope.parse(
                "t1:dGVzdC1tYXN0ZXIta2V5LW9uZS0zMi1ieXRlcy0hISE=");
        DataScope scope = DataScope.team(team);
        Secret secret = new Secret(SECRET, "", "", "", "", "", "", "", "");
        Reactive.tx(() -> repository.put(scope, "old", "bearer", key, previous.seal(secret.encode(), scope.aad("old")), alice));
        assertThat(value("SELECT key_id FROM data_credential WHERE team_id = ? AND name = 'old'", team)).isEqualTo("t1");
        assertThat(sentHeader(CAROL, teamDoc, "old", "authorization")).isEqualTo("Bearer " + SECRET);
        int rewrapped = Reactive.tx(() -> rotation.rotate());
        assertThat(rewrapped).isGreaterThanOrEqualTo(1);
        assertThat(count("SELECT count(*) FROM data_credential WHERE key_id <> ?", keys.envelope().currentKeyId())).isZero();
        assertThat(sentHeader(CAROL, teamDoc, "old", "authorization")).isEqualTo("Bearer " + SECRET);
        assertThat(Reactive.tx(() -> rotation.rotate())).isZero();
        Reactive.tx(() -> rotation.scheduled().replaceWith(0));
    }

    @Test
    void requestsAreLoggedWithSecretsRedacted() {
        List<String> lines = new ArrayList<>();
        Handler capture = new Handler() {
            @Override
            public void publish(LogRecord record) {
                lines.add(record instanceof ExtLogRecord ext ? ext.getFormattedMessage() : record.getMessage());
            }

            @Override
            public void flush() {
            }

            @Override
            public void close() {
            }
        };
        java.util.logging.Logger logger = java.util.logging.Logger.getLogger(DataSourceGrpcService.class.getName());
        logger.addHandler(capture);
        try {
            as(data, ALICE).putCredential(bearer(accountScope(alice), "logged", EgressStub.hostKey(host), SECRET).build());
        } finally {
            logger.removeHandler(capture);
        }
        assertThat(lines).anySatisfy(line -> assertThat(line).startsWith("PutCredential").contains("token: \"<redacted>\"")
                .contains("name: \"logged\""));
        assertThat(lines).allSatisfy(line -> assertThat(line).doesNotContain(SECRET));
    }
}
