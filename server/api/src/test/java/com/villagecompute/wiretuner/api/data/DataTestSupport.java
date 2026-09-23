package com.villagecompute.wiretuner.api.data;

import static com.villagecompute.wiretuner.api.TestUsers.ALICE;
import static com.villagecompute.wiretuner.api.TestUsers.BOB;
import static com.villagecompute.wiretuner.api.TestUsers.CAROL;
import static com.villagecompute.wiretuner.api.TestUsers.DAVE;
import static com.villagecompute.wiretuner.api.TestUsers.ERIN;
import static com.villagecompute.wiretuner.api.TestUsers.as;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ThreadLocalRandom;

import org.junit.jupiter.api.BeforeEach;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.api.DnsStub;
import com.villagecompute.wiretuner.api.EgressStub;
import com.villagecompute.wiretuner.api.ServiceTestSupport;
import com.villagecompute.wiretuner.api.TestUsers;
import com.villagecompute.wiretuner.data.v1.CredentialKind;
import com.villagecompute.wiretuner.data.v1.DataSourceServiceGrpc;
import com.villagecompute.wiretuner.data.v1.FetchRequest;
import com.villagecompute.wiretuner.data.v1.FetchResponse;
import com.villagecompute.wiretuner.data.v1.MutinyDataSourceServiceGrpc;
import com.villagecompute.wiretuner.data.v1.ProxyRequest;
import com.villagecompute.wiretuner.data.v1.PutAllowedHostRequest;
import com.villagecompute.wiretuner.data.v1.PutCredentialRequest;
import com.villagecompute.wiretuner.data.v1.RecordPage;
import com.villagecompute.wiretuner.data.v1.Scope;
import com.villagecompute.wiretuner.docs.v1.CreateRequest;
import com.villagecompute.wiretuner.docs.v1.DocumentServiceGrpc;
import com.villagecompute.wiretuner.doc.v1.HttpSource;

import io.quarkus.grpc.GrpcClient;

/**
 * The data-service tests' world: a team (alice owner, bob admin, carol member with the team's default
 * editor role, dave guest; erin outside), a team document and alice's personal document, stub upstream
 * hosts under {@code .wt.test} that resolve to the HTTPS stub, and helpers to permit hosts, store
 * credentials and run fetches.
 */
public abstract class DataTestSupport extends ServiceTestSupport {

    @GrpcClient("data")
    DataSourceServiceGrpc.DataSourceServiceBlockingStub data;

    @GrpcClient("data")
    MutinyDataSourceServiceGrpc.MutinyDataSourceServiceStub dataStreams;

    @GrpcClient("account")
    AccountServiceGrpc.AccountServiceBlockingStub account;

    @GrpcClient("documents")
    DocumentServiceGrpc.DocumentServiceBlockingStub docs;

    UUID alice;
    UUID bob;
    UUID carol;
    UUID dave;
    UUID erin;
    UUID team;
    UUID teamDoc;
    UUID personalDoc;
    /** A fresh stub host name for this test, resolving to the stub, and its path prefix. */
    String host;
    String prefix;

    @BeforeEach
    void world() {
        alice = TestUsers.accountId(account, ALICE);
        bob = TestUsers.accountId(account, BOB);
        carol = TestUsers.accountId(account, CAROL);
        dave = TestUsers.accountId(account, DAVE);
        erin = TestUsers.accountId(account, ERIN);
        team = team(alice, "editor");
        teamMember(team, bob, "admin");
        teamMember(team, carol, "member");
        teamMember(team, dave, "guest");
        teamDoc = document(ALICE, team);
        personalDoc = document(ALICE, alice);
        host = stubHost();
        prefix = "/" + UUID.randomUUID();
    }

    UUID document(String user, UUID space) {
        UUID id = uuid7();
        as(docs, user).create(CreateRequest.newBuilder().setDocumentId(id.toString()).setSpaceId(space.toString())
                .setName("Data").build());
        return id;
    }

    /** A new host name that resolves to the stub (127.0.0.1). */
    static String stubHost() {
        String name = "h" + Long.toHexString(ThreadLocalRandom.current().nextLong() & Long.MAX_VALUE) + ".wt.test";
        DnsStub.A.put(name, List.of("127.0.0.1"));
        return name;
    }

    static Scope teamScope(UUID team) {
        return Scope.newBuilder().setTeamId(team.toString()).build();
    }

    static Scope accountScope(UUID account) {
        return Scope.newBuilder().setAccountId(account.toString()).build();
    }

    /** Permits a stub host in a scope, as its manager. */
    void allow(String user, Scope scope, String stubHost) {
        as(data, user).putAllowedHost(PutAllowedHostRequest.newBuilder().setScope(scope).setHost(EgressStub.hostKey(stubHost)).build());
    }

    /** Permits this test's host in the team (as alice) and in alice's personal scope. */
    void allowEverywhere() {
        allow(ALICE, teamScope(team), host);
        allow(ALICE, accountScope(alice), host);
    }

    String url(String path) {
        return EgressStub.url(host, prefix + path);
    }

    String path(String path) {
        return prefix + path;
    }

    void route(String path, EgressStub.Handler handler) {
        EgressStub.ROUTES.put(prefix + path, handler);
    }

    List<EgressStub.Seen> seen(String path) {
        return EgressStub.seen(prefix + path);
    }

    static PutCredentialRequest.Builder bearer(Scope scope, String name, String hostKey, String token) {
        return PutCredentialRequest.newBuilder().setScope(scope).setName(name).setKind(CredentialKind.CREDENTIAL_KIND_BEARER)
                .setHost(hostKey).setToken(token);
    }

    ProxyRequest.Builder proxy(UUID document, String path) {
        return ProxyRequest.newBuilder().setDocumentId(document.toString()).setMethod("GET").setUrl(url(path));
    }

    FetchRequest.Builder fetch(UUID document, HttpSource.Builder source) {
        return FetchRequest.newBuilder().setDocumentId(document.toString()).setSource(source);
    }

    /** Every frame of a fetch, as the user. */
    List<FetchResponse> frames(String user, FetchRequest request) {
        List<FetchResponse> frames = new ArrayList<>();
        Iterator<FetchResponse> it = as(data, user).fetch(request);
        it.forEachRemaining(frames::add);
        return frames;
    }

    /** The record pages of a fetch. */
    List<RecordPage> pages(String user, FetchRequest request) {
        return frames(user, request).stream().filter(FetchResponse::hasPage).map(FetchResponse::getPage).toList();
    }

    /** Runs a stream fetch to its end, failing on the first error (for assertFails). */
    Runnable drain(String user, FetchRequest request) {
        return () -> frames(user, request);
    }
}
