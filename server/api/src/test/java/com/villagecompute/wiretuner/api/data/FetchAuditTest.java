package com.villagecompute.wiretuner.api.data;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.time.Duration;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.EgressStub;
import com.villagecompute.wiretuner.api.Reactive;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.data.v1.FetchAuditEntry;
import com.villagecompute.wiretuner.data.v1.FetchKind;
import com.villagecompute.wiretuner.data.v1.ListFetchAuditRequest;
import com.villagecompute.wiretuner.data.v1.ListFetchAuditResponse;
import com.villagecompute.wiretuner.doc.v1.ElementId;
import com.villagecompute.wiretuner.doc.v1.HttpSource;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.micrometer.core.instrument.MeterRegistry;
import io.quarkus.test.junit.QuarkusTest;

import jakarta.inject.Inject;

/**
 * DATA-008: the team's token bucket (a burst of 100 goes through at once, the next request waits
 * with RetryInfo; the test profile refills at 6 a minute so a slow run cannot refill a token), one audit row per call with who, document, host, status and counts but never a
 * query string, header or body, ListFetchAudit for admins with filters and paging, the 90-day
 * retention job, and the fetch metrics.
 */
@QuarkusTest
class FetchAuditTest extends DataTestSupport {

    @Inject
    FetchAuditRetentionJob retention;

    @Inject
    Outbound outbound;

    @Inject
    MeterRegistry registry;

    ListFetchAuditResponse audit(String user, ListFetchAuditRequest.Builder request) {
        return as(data, user).listFetchAudit(request.build());
    }

    @Test
    void aBurstOfOneHundredPassesAndTheNextWaits() {
        allowEverywhere();
        route("/tick", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        for (int i = 0; i < 100; i++) {
            as(data, CAROL).proxy(proxy(teamDoc, "/tick").build());
        }
        StatusRuntimeException limited = failure(() -> as(data, CAROL).proxy(proxy(teamDoc, "/tick").build()));
        assertThat(limited.getStatus().getCode()).isEqualTo(Status.Code.RESOURCE_EXHAUSTED);
        assertThat(StatusExceptions.reasonOf(limited)).contains(ErrorReasons.RATE_LIMITED);
        assertThat(StatusExceptions.retryDelayOf(limited)).hasValueSatisfying(delay -> assertThat(delay)
                .isPositive().isLessThanOrEqualTo(Duration.ofSeconds(10)));
        assertThat(seen("/tick")).hasSize(100);
        // The refusal is audited too, and admins see it.
        assertThat(audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team)).setPageSize(1)).getEntries(0).getStatus())
                .isEqualTo(ErrorReasons.RATE_LIMITED);
    }

    @Test
    void everyCallLeavesOneRowWithoutPayloads() {
        allowEverywhere();
        route("/items", (exchange, seen) -> EgressStub.json(exchange, "[{\"a\":1},{\"a\":2}]"));
        pages(CAROL, fetch(teamDoc, HttpSource.newBuilder().setUrl(url("/items?secret=s3") + "&page=1"))
                .setSourceId(ElementId.newBuilder().setCounter(12).setReplica(34)).addPaths("$.a").build());
        as(data, CAROL).proxy(proxy(teamDoc, "/items").setUrl(url("/items?token=abc")).putHeaders("X-Note", "hidden").build());
        route("/pic", (exchange, seen) -> EgressStub.send(exchange, 200, "image/gif", "GIF89a"));
        as(data, ALICE).fetchAsset(com.villagecompute.wiretuner.data.v1.FetchAssetRequest.newBuilder()
                .setDocumentId(teamDoc.toString()).setUrl(url("/pic?sig=1")).build());
        assertFails(() -> as(data, CAROL).proxy(proxy(teamDoc, "/items").setUrl(EgressStub.url(stubHost(), "/x?q=1")).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        List<FetchAuditEntry> entries = audit(ALICE, ListFetchAuditRequest.newBuilder().setScope(teamScope(team))).getEntriesList();
        assertThat(entries).hasSize(4);
        assertThat(entries).extracting(FetchAuditEntry::getKind).containsExactly(FetchKind.FETCH_KIND_SCRIPT,
                FetchKind.FETCH_KIND_ASSET, FetchKind.FETCH_KIND_SCRIPT, FetchKind.FETCH_KIND_SOURCE);
        FetchAuditEntry source = entries.get(3);
        assertThat(source.getStatus()).isEqualTo("OK");
        assertThat(source.getAccountId()).isEqualTo(carol.toString());
        assertThat(source.getDocumentId()).isEqualTo(teamDoc.toString());
        assertThat(source.getHost()).isEqualTo(EgressStub.hostKey(host));
        assertThat(source.getPath()).isEqualTo(path("/items"));
        assertThat(source.getPages()).isOne();
        assertThat(source.getRecords()).isEqualTo(2);
        assertThat(source.getBytes()).isPositive();
        assertThat(source.getSourceId().getCounter()).isEqualTo(12);
        assertThat(source.getFinishedAt().getSeconds()).isGreaterThanOrEqualTo(source.getStartedAt().getSeconds());
        assertThat(entries.get(2).hasSourceId()).isFalse();
        assertThat(entries.get(0).getStatus()).isEqualTo(ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(entries.get(1).getAccountId()).isEqualTo(alice.toString());
        for (FetchAuditEntry entry : entries) {
            String text = entry.toString();
            assertThat(text).doesNotContain("secret=").doesNotContain("token=").doesNotContain("sig=").doesNotContain("q=1")
                    .doesNotContain("hidden").doesNotContain("GIF89a");
        }
        assertThat(count("SELECT count(*) FROM data_fetch_audit WHERE team_id = ? AND position('?' in path) > 0", team)).isZero();
        assertThat(registry.find("wt.data.fetches").tag("kind", "source").tag("status", "OK").counter()).isNotNull();
        assertThat(registry.find("wt.data.fetch.bytes").tag("kind", "asset").counter().count()).isPositive();
    }

    @Test
    void theTrailIsForAdminsFilteredAndPaged() {
        allowEverywhere();
        route("/a", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        UUID otherDoc = document(ALICE, team);
        as(data, CAROL).proxy(proxy(teamDoc, "/a").build());
        as(data, BOB).proxy(proxy(otherDoc, "/a").build());
        as(data, CAROL).proxy(proxy(otherDoc, "/a").build());
        assertFails(() -> audit(CAROL, ListFetchAuditRequest.newBuilder().setScope(teamScope(team))), Status.Code.PERMISSION_DENIED,
                ErrorReasons.ROLE_INSUFFICIENT);
        assertFails(() -> audit(ERIN, ListFetchAuditRequest.newBuilder().setScope(teamScope(team))), Status.Code.NOT_FOUND,
                ErrorReasons.TEAM_NOT_FOUND);
        assertThat(audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team)).setDocumentId(otherDoc.toString()))
                .getEntriesCount()).isEqualTo(2);
        assertThat(audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team)).setAccountId(carol.toString()))
                .getEntriesCount()).isEqualTo(2);
        assertThat(audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team))
                .setHost(EgressStub.hostKey(host).toUpperCase())).getEntriesCount()).isEqualTo(3);
        assertThat(audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team)).setHost("elsewhere.example"))
                .getEntriesCount()).isZero();
        List<String> ids = new ArrayList<>();
        String cursor = "";
        do {
            ListFetchAuditResponse page = audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team)).setPageSize(2)
                    .setCursor(cursor));
            page.getEntriesList().forEach(e -> ids.add(e.getId()));
            cursor = page.getNextCursor();
        } while (!cursor.isEmpty());
        assertThat(ids).hasSize(3).doesNotHaveDuplicates();
        assertFails(() -> audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team)).setCursor("%%%")),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertFails(() -> audit(BOB, ListFetchAuditRequest.newBuilder().setScope(teamScope(team))
                .setCursor(com.villagecompute.wiretuner.api.grpc.Cursors.encode("not-a-time", UUID.randomUUID().toString()))),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        // A personal scope's trail is the account's own: fetches by the people it shared a document with included.
        share(personalDoc, erin, "editor");
        as(data, ERIN).proxy(proxy(personalDoc, "/a").build());
        assertThat(audit(ALICE, ListFetchAuditRequest.newBuilder().setScope(accountScope(alice)).setDocumentId(personalDoc.toString()))
                .getEntriesList()).extracting(FetchAuditEntry::getAccountId).containsExactly(erin.toString());
        assertFails(() -> audit(ERIN, ListFetchAuditRequest.newBuilder().setScope(accountScope(alice))), Status.Code.NOT_FOUND,
                ErrorReasons.SPACE_NOT_FOUND);
    }

    @Test
    void retentionDropsRowsOlderThanNinetyDays() {
        UUID old = UUID.randomUUID();
        UUID recent = UUID.randomUUID();
        String insert = "INSERT INTO data_fetch_audit (id, team_id, document_id, account_id, host, path, kind, started_at, finished_at,"
                + " status) VALUES (?, ?, ?, ?, 'h.example', '/', 'source', now() - ?::interval, now() - ?::interval, 'OK')";
        exec(insert, old, team, teamDoc, alice, "91 days", "91 days");
        exec(insert, recent, team, teamDoc, alice, "89 days", "89 days");
        int dropped = Reactive.tx(() -> retention.purge(Instant.now()));
        assertThat(dropped).isGreaterThanOrEqualTo(1);
        assertThat(count("SELECT count(*) FROM data_fetch_audit WHERE id = ?", old)).isZero();
        assertThat(count("SELECT count(*) FROM data_fetch_audit WHERE id = ?", recent)).isOne();
        Reactive.tx(() -> retention.scheduled().replaceWith(0));
        assertThat(count("SELECT count(*) FROM data_fetch_audit WHERE id = ?", recent)).isOne();
    }

    @Test
    void aCancelledFetchIsAuditedAsCancelled() throws InterruptedException {
        allowEverywhere();
        route("/slow", (exchange, seen) -> {
            FetchGuardTest.sleep(1500);
            EgressStub.json(exchange, "[]");
        });
        assertThat(failure(() -> as(data, ALICE).withDeadlineAfter(300, java.util.concurrent.TimeUnit.MILLISECONDS)
                .fetch(fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/slow"))).build()).forEachRemaining(f -> {
                })).getStatus().getCode()).isEqualTo(Status.Code.DEADLINE_EXCEEDED);
        List<FetchAuditEntry> entries = List.of();
        for (int i = 0; i < 50 && entries.isEmpty(); i++) {
            Thread.sleep(100);
            entries = audit(ALICE, ListFetchAuditRequest.newBuilder().setScope(accountScope(alice)).setDocumentId(personalDoc.toString()))
                    .getEntriesList();
        }
        assertThat(entries).singleElement().satisfies(e -> assertThat(e.getStatus()).isEqualTo("CANCELLED"));
    }

    @Test
    void aRunIsFinishedOnceAndAFailedAuditWriteIsOnlyLogged() {
        Scopes.Caller caller = new Scopes.Caller(new com.villagecompute.wiretuner.api.auth.Principal(alice, "s", null, "password",
                null, "r"), DataScope.account(alice));
        Run run = new Run(caller, personalDoc, "script");
        DataLimits limits = new DataLimits();
        limits.accountConcurrency = 1;
        run.lease = limits.admit(run.scope(), alice);
        run.path = "/has?query";
        Reactive.tx(() -> outbound.finish(run, null, false));
        Reactive.tx(() -> outbound.finish(run, null, false));
        assertThat(count("SELECT count(*) FROM data_fetch_audit WHERE document_id = ? AND path = '/has?query'", personalDoc)).isZero();
    }
}
