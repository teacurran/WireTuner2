package com.villagecompute.wiretuner.api.data;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.Redaction;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.api.persistence.Document;
import com.villagecompute.wiretuner.data.v1.CredentialKind;
import com.villagecompute.wiretuner.data.v1.FetchKind;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.data.v1.PutCredentialRequest;
import com.villagecompute.wiretuner.data.v1.Scope;
import com.villagecompute.wiretuner.doc.v1.HttpHeader;
import com.villagecompute.wiretuner.doc.v1.HttpMethod;
import com.villagecompute.wiretuner.doc.v1.HttpParam;
import com.villagecompute.wiretuner.doc.v1.HttpSource;
import com.villagecompute.wiretuner.doc.v1.Pagination;
import com.villagecompute.wiretuner.doc.v1.PaginationMode;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;

/** The data service's plain parts: header rules, templates, plans, secrets, limits, messages, redaction. */
class DataPartsTest {

    static String refusal(Runnable call) {
        try {
            call.run();
        } catch (StatusRuntimeException e) {
            return StatusExceptions.reasonOf(e).orElse(e.getStatus().getCode().name()) + ": " + e.getStatus().getDescription();
        }
        throw new AssertionError("accepted");
    }

    @Test
    void headerRules() {
        Map<String, String> ok = new LinkedHashMap<>();
        ok.put("Accept", "text/csv");
        ok.put("X-Trace", "1");
        ok.put("x-trace", "2");
        assertThat(RequestHeaders.check(ok, null, "h")).containsExactly(Map.entry("accept", "text/csv"), Map.entry("x-trace", "2"));
        for (String secret : List.of("Authorization", "PROXY-AUTHORIZATION", "cookie", "X-Api-Key")) {
            assertThat(refusal(() -> RequestHeaders.check(Map.of(secret, "v"), null, "h")))
                    .startsWith(ErrorReasons.VALIDATION_FAILED).contains(secret).contains("credential");
        }
        assertThat(refusal(() -> RequestHeaders.check(Map.of("X-Token", "v"), "x-token", "h"))).contains("X-Token");
        assertThat(refusal(() -> RequestHeaders.check(Map.of("Host", "evil"), null, "h"))).contains("set by the server");
        assertThat(refusal(() -> RequestHeaders.check(Map.of("Bad Name", "v"), null, "h"))).contains("not a header name");
    }

    @Test
    void templates() {
        HttpSource source = HttpSource.newBuilder()
                .addParams(HttpParam.newBuilder().setName("since").setDefaultValue("2024-01-01"))
                .addParams(HttpParam.newBuilder().setName("q").setDefaultValue("x")).build();
        Map<String, String> values = Templates.values(source, Map.of("q", "a b/c?d&e=f~*"));
        assertThat(Templates.url("https://h.example/{{ since }}/s?q={{q}}&m={{missing}}", values))
                .isEqualTo("https://h.example/2024-01-01/s?q=a%20b%2Fc%3Fd%26e%3Df~%2A&m=");
        assertThat(Templates.body("{\"q\":\"{{q}}\",\"$\":\"{{since}}\"}", values))
                .isEqualTo("{\"q\":\"a b/c?d&e=f~*\",\"$\":\"2024-01-01\"}");
        assertThat(Templates.withQueryParameter(URI.create("https://h.example/p?page=1&a=b&&c"), "page", "2"))
                .hasToString("https://h.example/p?a=b&c&page=2");
        assertThat(Templates.withQueryParameter(URI.create("https://h.example"), "p g", "1")).hasToString("https://h.example/?p%20g=1");
    }

    static FetchRequest fetch(HttpSource.Builder source, String... paths) {
        return FetchRequest.newBuilder().setDocumentId(UUID.randomUUID().toString()).setSource(source).addAllPaths(List.of(paths))
                .build();
    }

    @Test
    void planDefaultsAndCaps() {
        FetchPlan plain = FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/{{p}}")
                .addHeaders(HttpHeader.newBuilder().setName("Accept").setValue("application/vnd.x+json"))), 500);
        assertThat(plain.mode).isEqualTo(PaginationMode.PAGINATION_MODE_NONE);
        assertThat(plain.timeout).isEqualTo(Duration.ofSeconds(30));
        assertThat(plain.firstPage).isEqualTo(1);
        assertThat(plain.maxPages).isEqualTo(1000);
        assertThat(plain.maxRecords).isEqualTo(500);
        assertThat(plain.post()).isFalse();
        assertThat(plain.pageUrl(7)).hasToString("https://h.example/");
        assertThat(plain.headers(null)).containsEntry("accept", "application/vnd.x+json");
        FetchPlan paged = FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/l").setMethod(HttpMethod.HTTP_METHOD_POST)
                .setBodyTemplate("{}").setTimeoutS(5).setMaxRecords(10)
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_PAGE_PARAM).setPageParam("page")
                        .setFirstPage(0).setMaxPages(5000))), 500);
        assertThat(paged.maxPages).isEqualTo(1000);
        assertThat(paged.maxRecords).isEqualTo(10);
        assertThat(paged.timeout).isEqualTo(Duration.ofSeconds(5));
        assertThat(paged.post()).isTrue();
        assertThat(paged.pageUrl(3)).hasToString("https://h.example/l?page=3");
        assertThat(paged.headers(null)).containsEntry("accept", "application/json");
        assertThat(new String(paged.body(), StandardCharsets.UTF_8)).isEqualTo("{}");
        FetchPlan capped = FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/").setMaxRecords(900)
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.next")
                        .setFirstPage(4).setMaxPages(3))), 500);
        assertThat(capped.maxRecords).isEqualTo(500);
        assertThat(capped.maxPages).isEqualTo(3);
        assertThat(capped.firstPage).isEqualTo(4);
    }

    @Test
    void planRefusals() {
        assertThat(refusal(() -> FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/")
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL))), 1)))
                .contains("source.pagination.next_url_path");
        assertThat(refusal(() -> FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/")
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_PAGE_PARAM))), 1)))
                .contains("source.pagination.page_param");
        assertThat(refusal(() -> FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/").setRecordsPath("$[?(@)]")), 1)))
                .contains("source.records_path").contains("filter");
        assertThat(refusal(() -> FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/"), "$.ok", "$[0:1]"), 1)))
                .contains("paths[1]");
        FetchPlan plan = FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/")
                .addHeaders(HttpHeader.newBuilder().setName("Cookie").setValue("s"))), 1);
        assertThat(refusal(() -> plan.headers(null))).contains("source.headers").contains("Cookie");
    }

    static Egress.Reply reply(String url) {
        return new Egress.Reply(200, List.of(), new byte[0], URI.create(url));
    }

    @Test
    void nextPositions() throws Exception {
        FetchPlan next = FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/")
                .setPagination(Pagination.newBuilder().setMode(PaginationMode.PAGINATION_MODE_NEXT_URL).setNextUrlPath("$.next"))), 100);
        FetchCursor at = new FetchCursor("", 1, 0, 0);
        Object relative = JsonTree.parse("{\"next\":\"/p?page=2\"}".getBytes(StandardCharsets.UTF_8));
        assertThat(Fetches.next(next, at, reply("https://h.example/p?page=1"), relative, false, 1, 10))
                .isEqualTo(new FetchCursor("https://h.example/p?page=2", 0, 1, 10));
        assertThat(Fetches.next(next, at, reply("https://h.example/"), JsonTree.parse("{\"next\":\"\"}".getBytes()), false, 1, 1)).isNull();
        assertThat(Fetches.next(next, at, reply("https://h.example/"), JsonTree.parse("{}".getBytes()), false, 1, 1)).isNull();
        assertThat(Fetches.next(next, at, reply("https://h.example/"), relative, false, 1000, 1)).isNull();
        assertThat(Fetches.next(next, at, reply("https://h.example/"), relative, false, 1, 100)).isNull();
        for (String bad : List.of("http://h.example/2", "ht tp://x", "https://user@h.example/", "https://2130706433/")) {
            Object json = JsonTree.parse(("{\"next\":\"" + bad + "\"}").getBytes(StandardCharsets.UTF_8));
            assertThat(refusal(() -> Fetches.next(next, at, reply("https://h.example/"), json, false, 1, 1)))
                    .startsWith(ErrorReasons.UPSTREAM_ERROR);
        }
        FetchPlan none = FetchPlan.of(fetch(HttpSource.newBuilder().setUrl("https://h.example/")), 100);
        assertThat(Fetches.next(none, at, reply("https://h.example/"), relative, false, 1, 1)).isNull();
    }

    @Test
    void jsonMediaTypes() {
        assertThat(Fetches.json("application/json")).isTrue();
        assertThat(Fetches.json("Application/JSON; charset=utf-8")).isTrue();
        assertThat(Fetches.json("application/problem+json")).isTrue();
        assertThat(Fetches.json("text/html")).isFalse();
        assertThat(Fetches.json(null)).isFalse();
    }

    @Test
    void secretsNeverPrint() {
        PutCredentialRequest put = PutCredentialRequest.newBuilder().setScope(Scope.newBuilder().setTeamId(UUID.randomUUID().toString()))
                .setName("api").setKind(CredentialKind.CREDENTIAL_KIND_OAUTH2_CLIENT).setHost("h.example")
                .setClientId("client").setClientSecret("hunter2").setTokenUrl("https://h.example/token").setOauthScope("read")
                .build();
        Secret secret = Secret.of(put);
        assertThat(secret).hasToString("Secret<redacted>");
        assertThat(Secret.decode(secret.encode())).isEqualTo(secret);
        String printed = Redaction.print(put);
        assertThat(printed).contains("client_secret: \"<redacted>\"").contains("client_id: \"client\"").doesNotContain("hunter2");
        String bearer = Redaction.print(put.toBuilder().clearClientSecret().setToken("tok-123").setPassword("pw-456")
                .setHeaderValue("hv-789").build());
        assertThat(bearer).doesNotContain("tok-123").doesNotContain("pw-456").doesNotContain("hv-789");
        assertThat(Redaction.print(FetchRequest.newBuilder().putParams("k", "v")
                .setSource(HttpSource.newBuilder().addHeaders(HttpHeader.newBuilder().setName("A").setValue("b"))).build()))
                .contains("key: \"k\"").contains("name: \"A\"");
    }

    @Test
    void kindNames() {
        for (CredentialKind kind : List.of(CredentialKind.CREDENTIAL_KIND_BEARER, CredentialKind.CREDENTIAL_KIND_BASIC,
                CredentialKind.CREDENTIAL_KIND_HEADER, CredentialKind.CREDENTIAL_KIND_OAUTH2_CLIENT)) {
            assertThat(Secret.kind(Secret.kindName(kind))).isEqualTo(kind);
        }
        assertThat(DataMessages.kind("source")).isEqualTo(FetchKind.FETCH_KIND_SOURCE);
        assertThat(DataMessages.kind("script")).isEqualTo(FetchKind.FETCH_KIND_SCRIPT);
        assertThat(DataMessages.kind("asset")).isEqualTo(FetchKind.FETCH_KIND_ASSET);
        assertThat(DataMessages.id(null)).isEmpty();
    }

    @Test
    void scopes() {
        UUID team = UUID.randomUUID();
        UUID owner = UUID.randomUUID();
        Document teamDoc = new Document();
        teamDoc.teamId = team;
        teamDoc.ownerAccountId = owner;
        Document personal = new Document();
        personal.ownerAccountId = owner;
        assertThat(DataScope.of(teamDoc)).isEqualTo(DataScope.team(team));
        assertThat(DataScope.of(personal)).isEqualTo(DataScope.account(owner));
        assertThat(DataScope.team(team).key()).isEqualTo("team:" + team);
        assertThat(DataScope.account(owner).column()).isEqualTo("account_id");
        assertThat(DataScope.account(owner).id()).isEqualTo(owner);
    }

    @Test
    void concurrencyCaps() {
        DataLimits limits = new DataLimits();
        limits.teamConcurrency = 2;
        limits.accountConcurrency = 1;
        DataScope team = DataScope.team(UUID.randomUUID());
        UUID a = UUID.randomUUID();
        UUID b = UUID.randomUUID();
        UUID c = UUID.randomUUID();
        DataLimits.Lease first = limits.admit(team, a);
        assertThat(refusal(() -> limits.admit(team, a))).startsWith(ErrorReasons.RATE_LIMITED);
        DataLimits.Lease second = limits.admit(team, b);
        assertThat(refusal(() -> limits.admit(team, c))).startsWith(ErrorReasons.RATE_LIMITED);
        first.release();
        DataLimits.Lease third = limits.admit(team, c);
        DataLimits.Lease personal = limits.admit(DataScope.account(a), a);
        assertThat(refusal(() -> limits.admit(DataScope.account(a), a))).startsWith(ErrorReasons.RATE_LIMITED);
        second.release();
        third.release();
        personal.release();
        assertThat(limits.active.values()).allMatch(count -> count.get() == 0);
        assertThat(DataLimits.teamKey(a)).isEqualTo("rl:dt:" + a);
    }

    @Test
    void oauthGrants() {
        assertThat(CredentialVault.grant("{\"access_token\":\"t\",\"expires_in\":3600}".getBytes()))
                .isEqualTo(new CredentialVault.Grant("t", 3600));
        assertThat(CredentialVault.grant("{\"access_token\":\"t\"}".getBytes()).expiresInSeconds()).isZero();
        for (String bad : List.of("not json", "[]", "{\"expires_in\":1}", "{\"access_token\":\"\"}", "{\"access_token\":1}")) {
            assertThat(refusal(() -> CredentialVault.grant(bad.getBytes()))).startsWith(ErrorReasons.UPSTREAM_ERROR);
        }
        assertThat(CredentialVault.basic("Aladdin", "open sesame")).isEqualTo("QWxhZGRpbjpvcGVuIHNlc2FtZQ==");
        assertThat(CredentialVault.TOKEN_CAP).isEqualTo(1_048_576L);
    }

    @Test
    void proxyAnswers() {
        Egress.Reply reply = new Egress.Reply(418, List.of(Map.entry("x-a", "1"), Map.entry("x-a", "2"), Map.entry("set-cookie", "s=1"),
                Map.entry("connection", "close"), Map.entry("content-type", "text/plain")), "tea".getBytes(), URI.create("https://h.example/"));
        var response = DataSourceGrpcService.proxyResponse(reply);
        assertThat(response.getStatus()).isEqualTo(418);
        assertThat(response.getHeadersMap()).containsExactlyInAnyOrderEntriesOf(Map.of("x-a", "1, 2", "content-type", "text/plain"));
        assertThat(response.getBody().toStringUtf8()).isEqualTo("tea");
        assertThat(reply.header("Content-Type")).isEqualTo("text/plain");
        assertThat(reply.header("missing")).isNull();
        assertThat(DataSourceGrpcService.mediaType(null)).isEqualTo("application/octet-stream");
        assertThat(DataSourceGrpcService.mediaType("Image/PNG; q=1")).isEqualTo("image/png");
        assertThat(DataSourceGrpcService.optionalId("")).isNull();
        assertThat(refusal(() -> DataSourceGrpcService.instant("yesterday"))).startsWith(ErrorReasons.VALIDATION_FAILED);
    }

    @Test
    void auditStatus() {
        assertThat(Outbound.status(StatusExceptions.hostNotAllowed("h"))).isEqualTo(ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(Outbound.status(Status.DEADLINE_EXCEEDED.asRuntimeException())).isEqualTo("DEADLINE_EXCEEDED");
        assertThat(Outbound.status(new IllegalStateException())).isEqualTo("UNKNOWN");
    }

    @Test
    void openedCredentialHeaders() {
        CredentialRepository.Stored header = new CredentialRepository.Stored(UUID.randomUUID(), "k", "header", "h", null, "", null,
                null, null);
        Secret secret = new Secret("", "", "", "X-Key", "v", "", "", "", "");
        assertThat(new CredentialVault.Opened(header, secret).headerName()).isEqualTo("x-key");
        CredentialRepository.Stored bearer = new CredentialRepository.Stored(UUID.randomUUID(), "k", "bearer", "h", null, "", null,
                null, null);
        assertThat(new CredentialVault.Opened(bearer, secret).headerName()).isEqualTo("authorization");
    }
}
