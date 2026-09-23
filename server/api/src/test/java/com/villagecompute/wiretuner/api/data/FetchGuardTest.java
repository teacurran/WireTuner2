package com.villagecompute.wiretuner.api.data;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.as;
import static org.assertj.core.api.Assertions.assertThat;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.HexFormat;
import java.util.List;
import java.util.Random;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

import org.junit.jupiter.api.Test;

import com.google.protobuf.ByteString;
import com.google.rpc.ErrorInfo;
import com.villagecompute.wiretuner.api.DnsStub;
import com.villagecompute.wiretuner.api.EgressStub;
import com.villagecompute.wiretuner.api.grpc.ErrorReasons;
import com.villagecompute.wiretuner.api.grpc.StatusExceptions;
import com.villagecompute.wiretuner.data.v1.CredentialKind;
import com.villagecompute.wiretuner.data.v1.FetchAssetRequest;
import com.villagecompute.wiretuner.data.v1.FetchAssetResponse;
import com.villagecompute.wiretuner.data.v1.ProxyResponse;
import com.villagecompute.wiretuner.data.v1.PutCredentialRequest;
import com.villagecompute.wiretuner.doc.v1.HttpHeader;
import com.villagecompute.wiretuner.doc.v1.HttpSource;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.test.junit.QuarkusTest;

/**
 * DATA-006 and DATA-007 against the HTTPS stub: https only; hosts resolving to private, loopback,
 * link-local or metadata addresses refused before connecting; the connection pinned to the address
 * checked (a changed DNS answer is never used); redirects followed only to the same host; response
 * caps; the header denylist; timeouts, TLS verification and unreachable hosts as UPSTREAM_ERROR; the
 * OAuth token fetched once for many requests; FetchAsset storing a blob; and the allowlist checked
 * before any connection.
 */
@QuarkusTest
class FetchGuardTest extends DataTestSupport {

    static final int MIB = 1024 * 1024;

    StatusRuntimeException refused(Runnable call, Status.Code code, String reason) {
        StatusRuntimeException e = failure(call);
        assertThat(e.getStatus().getCode()).as(e.getStatus().getDescription()).isEqualTo(code);
        assertThat(StatusExceptions.reasonOf(e)).as(e.getStatus().getDescription()).contains(reason);
        return e;
    }

    @Test
    void httpIsRefused() {
        allowEverywhere();
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/x").setUrl("http://" + EgressStub.hostKey(host) + "/x").build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        refused(() -> as(data, ALICE).fetchAsset(FetchAssetRequest.newBuilder().setDocumentId(personalDoc.toString())
                .setUrl("http://" + host + "/x").build()), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        refused(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl("http://" + host + "/x")).build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        refused(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder()).build()), Status.Code.INVALID_ARGUMENT,
                ErrorReasons.VALIDATION_FAILED);
        // A parameter cannot turn the URL into something else.
        refused(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl("https://{{h}}/x")).putParams("h", "").build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/x").setUrl("https://user:pw@" + EgressStub.hostKey(host) + "/x")
                .build()), Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
    }

    /** A permitted stub host that resolves to the given addresses. */
    String resolvingTo(List<String> v4, List<String> v6) {
        String name = stubHost();
        DnsStub.A.put(name, v4);
        if (v6 != null) {
            DnsStub.AAAA.put(name, v6);
        }
        allow(ALICE, accountScope(alice), name);
        return name;
    }

    @Test
    void privateAndMetadataAddressesAreRefusedBeforeConnecting() {
        route("/secret", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        for (List<List<String>> answers : List.of(List.of(List.of("10.0.0.5")), List.of(List.of("169.254.169.254")),
                List.of(List.of("127.0.0.1", "192.168.1.10")), List.of(List.of("127.0.0.1"), List.of("fd00:ec2::254")),
                List.of(List.of("127.0.0.1"), List.of("::ffff:10.0.0.5")), List.of(List.<String>of(), List.of("::1")))) {
            String name = resolvingTo(answers.get(0), answers.size() > 1 ? answers.get(1) : null);
            StatusRuntimeException e = refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/secret")
                    .setUrl(EgressStub.url(name, path("/secret"))).build()), Status.Code.PERMISSION_DENIED,
                    ErrorReasons.HOST_NOT_ALLOWED);
            assertThat(e.getStatus().getDescription()).contains("does not connect");
        }
        assertThat(seen("/secret")).isEmpty();
        // An IP literal is checked the same way, without a lookup.
        allow(ALICE, accountScope(alice), "10.0.0.5");
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/secret").setUrl("https://10.0.0.5:" + EgressStub.port + path("/secret"))
                .build()), Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        // A public address beside the stub's passes the check (and the first answer is the one used).
        String mixed = resolvingTo(List.of("127.0.0.1", "8.8.8.8"), List.of("2606:4700:4700::1111"));
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/secret").setUrl(EgressStub.url(mixed, path("/secret"))).build())
                .getStatus()).isEqualTo(200);
        assertThat(seen("/secret")).hasSize(1);
    }

    @Test
    void theConnectionIsPinnedToTheCheckedAddress() {
        String name = resolvingTo(List.of("127.0.0.1"), null);
        route("/a", (exchange, seen) -> {
            // Rebind: from now on the name resolves to a private address.
            DnsStub.A.put(name, List.of("10.0.0.5"));
            EgressStub.redirect(exchange, 302, path("/b"));
        });
        route("/b", (exchange, seen) -> EgressStub.json(exchange, "{\"pinned\":true}"));
        ProxyResponse response = as(data, ALICE).proxy(proxy(personalDoc, "/a").setUrl(EgressStub.url(name, path("/a"))).build());
        assertThat(response.getBody().toStringUtf8()).isEqualTo("{\"pinned\":true}");
        assertThat(seen("/b")).hasSize(1);
        assertThat(seen("/b").get(0).host()).isEqualTo(EgressStub.hostKey(name));
        assertThat(DnsStub.QUERIES.get(name + "/1").get()).isEqualTo(1);
    }

    @Test
    void redirectsStayOnTheHost() {
        allowEverywhere();
        String other = stubHost();
        allow(ALICE, accountScope(alice), other);
        route("/away", (exchange, seen) -> EgressStub.redirect(exchange, 301, EgressStub.url(other, path("/there"))));
        route("/plain", (exchange, seen) -> EgressStub.redirect(exchange, 302, "http://" + EgressStub.hostKey(host) + path("/there")));
        route("/nohost", (exchange, seen) -> EgressStub.redirect(exchange, 307, "https:/there"));
        route("/there", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        StatusRuntimeException away = refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/away").build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(StatusExceptions.errorInfo(away).map(ErrorInfo::getMetadataMap).orElseThrow()).containsEntry("host", other);
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/plain").build()), Status.Code.PERMISSION_DENIED,
                ErrorReasons.HOST_NOT_ALLOWED);
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/nohost").build()), Status.Code.PERMISSION_DENIED,
                ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(seen("/there")).isEmpty();
        // Same-host redirects: at most three; 303 turns a POST into a GET.
        AtomicInteger hops = new AtomicInteger();
        route("/loop", (exchange, seen) -> EgressStub.redirect(exchange, 308, path("/loop?n=" + hops.incrementAndGet())));
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/loop").build()), Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR);
        assertThat(seen("/loop")).hasSize(4);
        route("/post", (exchange, seen) -> EgressStub.redirect(exchange, 303, path("/done")));
        route("/done", (exchange, seen) -> EgressStub.json(exchange, "{\"method\":\"" + seen.method() + "\"}"));
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/post").setMethod("POST").setBody(ByteString.copyFromUtf8("{}")).build())
                .getBody().toStringUtf8()).isEqualTo("{\"method\":\"GET\"}");
        assertThat(seen("/post").get(0).bodyText()).isEqualTo("{}");
        route("/keep", (exchange, seen) -> EgressStub.redirect(exchange, 307, path("/done")));
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/keep").setMethod("PUT").setBody(ByteString.copyFromUtf8("x")).build())
                .getBody().toStringUtf8()).isEqualTo("{\"method\":\"PUT\"}");
        // A 3xx without a Location, and a 304, are answers like any other.
        route("/bare", (exchange, seen) -> EgressStub.send(exchange, 302, null, new byte[0]));
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/bare").build()).getStatus()).isEqualTo(302);
        route("/cached", (exchange, seen) -> {
            exchange.getResponseHeaders().add("Location", "https://elsewhere.example/");
            exchange.sendResponseHeaders(304, -1);
        });
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/cached").build()).getStatus()).isEqualTo(304);
    }

    @Test
    void responsesAreCapped() {
        allowEverywhere();
        route("/huge", (exchange, seen) -> EgressStub.chunked(exchange, "application/json", 65L * MIB));
        refused(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/huge"))).build()),
                Status.Code.RESOURCE_EXHAUSTED, ErrorReasons.RESPONSE_TOO_LARGE);
        route("/declared", (exchange, seen) -> {
            exchange.getResponseHeaders().add("Content-Type", "application/octet-stream");
            exchange.sendResponseHeaders(200, 17L * MIB);
            exchange.getResponseBody().write(new byte[1024]);
        });
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/declared").build()), Status.Code.RESOURCE_EXHAUSTED,
                ErrorReasons.RESPONSE_TOO_LARGE);
        route("/small", (exchange, seen) -> EgressStub.send(exchange, 200, "text/plain", "ok"));
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/small").build()).getBody().toStringUtf8()).isEqualTo("ok");
    }

    @Test
    void credentialHeadersInTheDefinitionAreRefused() {
        allowEverywhere();
        route("/h", (exchange, seen) -> EgressStub.json(exchange, "[]"));
        StatusRuntimeException e = refused(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/h"))
                .addHeaders(HttpHeader.newBuilder().setName("Authorization").setValue("Bearer x"))).build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        // doc.v1's own rule on HttpHeader.name refuses it before the proxy's denylist does.
        assertThat(e.getStatus().getDescription()).contains("credential headers are not allowed");
        refused(drain(ALICE, fetch(personalDoc, HttpSource.newBuilder().setUrl(url("/h"))
                .addHeaders(HttpHeader.newBuilder().setName("Transfer-Encoding").setValue("chunked"))).build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/h").putHeaders("Cookie", "s=1").build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/h").putHeaders("Host", "evil.example").build()),
                Status.Code.INVALID_ARGUMENT, ErrorReasons.VALIDATION_FAILED);
        assertThat(seen("/h")).isEmpty();
        // Ordinary headers pass through; the stub's cookies do not come back.
        route("/ok", (exchange, seen) -> {
            exchange.getResponseHeaders().add("Set-Cookie", "session=1");
            exchange.getResponseHeaders().add("X-Echo", seen.header("x-trace"));
            EgressStub.json(exchange, "{}");
        });
        ProxyResponse ok = as(data, ALICE).proxy(proxy(personalDoc, "/ok").putHeaders("X-Trace", "t1").build());
        assertThat(ok.getHeadersMap()).containsEntry("x-echo", "t1").doesNotContainKey("set-cookie");
    }

    @Test
    void unreachableSlowAndUnverifiableHostsAreUpstreamErrors() {
        allowEverywhere();
        // Nothing listens on the port.
        String closed = "https://" + host + ":1" + path("/x");
        as(data, ALICE).putAllowedHost(com.villagecompute.wiretuner.data.v1.PutAllowedHostRequest.newBuilder()
                .setScope(accountScope(alice)).setHost(host + ":1").build());
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/x").setUrl(closed).build()), Status.Code.UNAVAILABLE,
                ErrorReasons.UPSTREAM_ERROR);
        // The name does not resolve.
        String unknown = "nx" + System.nanoTime() + ".wt.test";
        allow(ALICE, accountScope(alice), unknown);
        StatusRuntimeException nx = refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/x").setUrl(EgressStub.url(unknown, "/x"))
                .build()), Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR);
        assertThat(nx.getStatus().getDescription()).contains("does not resolve");
        // The certificate does not cover the name.
        String mismatch = "stub" + System.nanoTime() + ".example";
        DnsStub.A.put(mismatch, List.of("127.0.0.1"));
        allow(ALICE, accountScope(alice), mismatch);
        route("/tls", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/tls").setUrl(EgressStub.url(mismatch, path("/tls"))).build()),
                Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR);
        assertThat(seen("/tls")).isEmpty();
        // Slower than the timeout.
        route("/slow", (exchange, seen) -> {
            sleep(2500);
            EgressStub.json(exchange, "{}");
        });
        StatusRuntimeException slow = refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/slow").setTimeoutS(1).build()),
                Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR);
        assertThat(slow.getStatus().getDescription()).contains("did not answer");
        // A caller that gives up cancels the upstream request.
        assertThat(failure(() -> as(data, ALICE).withDeadlineAfter(500, TimeUnit.MILLISECONDS).proxy(proxy(personalDoc, "/slow")
                .build())).getStatus().getCode()).isEqualTo(Status.Code.DEADLINE_EXCEEDED);
    }

    static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    @Test
    void anIpLiteralUrlIsFetchedWithoutALookup() {
        allow(ALICE, accountScope(alice), "127.0.0.1");
        route("/lit", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/lit").setUrl("https://127.0.0.1:" + EgressStub.port + path("/lit"))
                .build()).getStatus()).isEqualTo(200);
        // A URL without a path asks for "/" (the stub has no route there).
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/lit").setUrl("https://127.0.0.1:" + EgressStub.port).build())
                .getStatus()).isEqualTo(404);
        assertThat(EgressStub.SEEN).anySatisfy(seen -> assertThat(seen.path()).isEqualTo("/"));
    }

    @Test
    void aCredentialGoesOnlyToItsHost() {
        allowEverywhere();
        String other = stubHost();
        allow(ALICE, accountScope(alice), other);
        as(data, ALICE).putCredential(bearer(accountScope(alice), "bound", EgressStub.hostKey(other), "t").build());
        route("/x", (exchange, seen) -> EgressStub.json(exchange, "{}"));
        StatusRuntimeException e = refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/x").setCredentialName("bound").build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(e.getStatus().getDescription()).contains("only sent to");
        assertThat(seen("/x")).isEmpty();
    }

    @Test
    void theOAuthTokenIsFetchedOnceForTenRequests() {
        allowEverywhere();
        String idp = stubHost();
        AtomicInteger grants = new AtomicInteger();
        route("/token", (exchange, seen) -> {
            grants.incrementAndGet();
            assertThat(seen.method()).isEqualTo("POST");
            assertThat(seen.bodyText()).isEqualTo("grant_type=client_credentials&scope=read%20write");
            assertThat(seen.header("authorization")).isEqualTo("Basic " + java.util.Base64.getEncoder()
                    .encodeToString("my%20client:s%3Acret".getBytes(StandardCharsets.UTF_8)));
            EgressStub.json(exchange, "{\"access_token\":\"at-" + grants.get() + "\",\"token_type\":\"bearer\",\"expires_in\":3600}");
        });
        route("/api", (exchange, seen) -> EgressStub.json(exchange, "{\"auth\":\"" + seen.header("authorization") + "\"}"));
        PutCredentialRequest.Builder oauth = PutCredentialRequest.newBuilder().setScope(teamScope(team)).setName("oauth")
                .setKind(CredentialKind.CREDENTIAL_KIND_OAUTH2_CLIENT).setHost(EgressStub.hostKey(host)).setClientId("my client")
                .setClientSecret("s:cret").setTokenUrl(EgressStub.url(idp, path("/token"))).setOauthScope("read write");
        as(data, BOB).putCredential(oauth.build());
        for (int i = 0; i < 10; i++) {
            assertThat(as(data, CAROL).proxy(proxy(teamDoc, "/api").setCredentialName("oauth").build()).getBody().toStringUtf8())
                    .isEqualTo("{\"auth\":\"Bearer at-1\"}");
        }
        assertThat(grants.get()).isEqualTo(1);
        // Replacing the credential starts over; a token with a short life is not kept.
        route("/token", (exchange, seen) -> {
            grants.incrementAndGet();
            EgressStub.json(exchange, "{\"access_token\":\"short-" + grants.get() + "\",\"expires_in\":30}");
        });
        as(data, BOB).putCredential(oauth.setOauthScope("").build());
        as(data, CAROL).proxy(proxy(teamDoc, "/api").setCredentialName("oauth").build());
        as(data, CAROL).proxy(proxy(teamDoc, "/api").setCredentialName("oauth").build());
        assertThat(grants.get()).isEqualTo(3);
        // A failing token endpoint fails the call and is asked again next time.
        route("/token", (exchange, seen) -> {
            grants.incrementAndGet();
            EgressStub.send(exchange, 401, "application/json", "{\"error\":\"invalid_client\"}");
        });
        as(data, BOB).putCredential(oauth.setClientSecret("wrong").build());
        StatusRuntimeException e = refused(() -> as(data, CAROL).proxy(proxy(teamDoc, "/api").setCredentialName("oauth").build()),
                Status.Code.UNAVAILABLE, ErrorReasons.UPSTREAM_ERROR);
        assertThat(StatusExceptions.errorInfo(e).orElseThrow().getMetadataMap()).containsEntry("upstream_status", "401");
        refused(() -> as(data, CAROL).proxy(proxy(teamDoc, "/api").setCredentialName("oauth").build()), Status.Code.UNAVAILABLE,
                ErrorReasons.UPSTREAM_ERROR);
        assertThat(grants.get()).isEqualTo(5);
    }

    @Test
    void fetchAssetStoresTheBlobForTheDocument() throws Exception {
        allowEverywhere();
        byte[] image = new byte[5 * MIB];
        new Random(7).nextBytes(image);
        String sha = HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(image));
        route("/photo.png", (exchange, seen) -> EgressStub.send(exchange, 200, "image/png; charset=binary", image));
        FetchAssetRequest request = FetchAssetRequest.newBuilder().setDocumentId(teamDoc.toString()).setUrl(url("/photo.png")).build();
        FetchAssetResponse asset = as(data, CAROL).fetchAsset(request);
        assertThat(HexFormat.of().formatHex(asset.getBlobSha256().toByteArray())).isEqualTo(sha);
        assertThat(asset.getMediaType()).isEqualTo("image/png");
        assertThat(asset.getSize()).isEqualTo(image.length);
        assertThat(count("SELECT count(*) FROM document_blob WHERE document_id = ? AND sha256 = ?", teamDoc, sha)).isOne();
        // The same picture for another document is referenced, not stored again.
        FetchAssetResponse again = as(data, ALICE).fetchAsset(request.toBuilder().setDocumentId(personalDoc.toString()).build());
        assertThat(again.getBlobSha256()).isEqualTo(asset.getBlobSha256());
        assertThat(count("SELECT count(*) FROM document_blob WHERE document_id = ? AND sha256 = ?", personalDoc, sha)).isOne();
        route("/gone.png", (exchange, seen) -> EgressStub.send(exchange, 404, "text/plain", "no"));
        refused(() -> as(data, CAROL).fetchAsset(request.toBuilder().setUrl(url("/gone.png")).build()), Status.Code.UNAVAILABLE,
                ErrorReasons.UPSTREAM_ERROR);
        route("/untyped", (exchange, seen) -> EgressStub.send(exchange, 200, null, "bytes"));
        assertThat(as(data, CAROL).fetchAsset(request.toBuilder().setUrl(url("/untyped")).build()).getMediaType())
                .isEqualTo("application/octet-stream");
        refused(() -> as(data, CAROL).fetchAsset(request.toBuilder().setUrl(url("/photo.png")).setCredentialName("none").build()),
                Status.Code.FAILED_PRECONDITION, ErrorReasons.CREDENTIAL_MISSING);
    }

    @Test
    void anUnlistedHostFailsBeforeAnyConnection() {
        route("/list", (exchange, seen) -> EgressStub.json(exchange, "[{\"a\":1}]"));
        String bobName = (String) value("SELECT coalesce(nullif(display_name, ''), email) FROM account WHERE id = ?", bob);
        StatusRuntimeException team = refused(drain(CAROL, fetch(teamDoc, HttpSource.newBuilder().setUrl(url("/list"))).build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(StatusExceptions.errorInfo(team).orElseThrow().getMetadataMap())
                .containsEntry("host", EgressStub.hostKey(host)).hasEntrySatisfying("admins", admins -> assertThat(admins)
                        .contains(bobName));
        StatusRuntimeException personal = refused(() -> as(data, ALICE).proxy(proxy(personalDoc, "/list").build()),
                Status.Code.PERMISSION_DENIED, ErrorReasons.HOST_NOT_ALLOWED);
        assertThat(StatusExceptions.errorInfo(personal).orElseThrow().getMetadataMap()).doesNotContainKey("admins");
        assertThat(seen("/list")).isEmpty();
        // The consent sheet permits it on the account; the team's admin permits it for the team.
        allow(ALICE, accountScope(alice), host);
        assertThat(as(data, ALICE).proxy(proxy(personalDoc, "/list").build()).getStatus()).isEqualTo(200);
        allow(BOB, teamScope(this.team), host);
        assertThat(pages(CAROL, fetch(teamDoc, HttpSource.newBuilder().setUrl(url("/list"))).addPaths("$.a").build()))
                .singleElement().satisfies(page -> assertThat(page.getRecords(0).getValuesMap()).containsEntry("$.a", "1"));
        // Guests and outsiders do not fetch.
        refused(() -> as(data, com.villagecompute.wiretuner.api.TestUsers.DAVE).proxy(proxy(teamDoc, "/list").build()),
                Status.Code.NOT_FOUND, ErrorReasons.DOCUMENT_NOT_FOUND);
    }
}
