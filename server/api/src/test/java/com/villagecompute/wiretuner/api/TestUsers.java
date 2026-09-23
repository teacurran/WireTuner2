package com.villagecompute.wiretuner.api;

import java.time.Duration;
import java.time.Instant;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import com.villagecompute.wiretuner.account.v1.AccountServiceGrpc;
import com.villagecompute.wiretuner.account.v1.MeRequest;
import com.villagecompute.wiretuner.api.grpc.GrpcMetadata;

import io.grpc.Metadata;
import io.grpc.stub.AbstractStub;
import io.grpc.stub.MetadataUtils;
import io.quarkus.test.keycloak.client.KeycloakTestClient;

/**
 * The realm's test people (alice, bob, carol, dave, erin; password {@code testpass}) as gRPC callers:
 * real access tokens from the Dev Service Keycloak, cached below their 15-minute lifetime, and their
 * account ids, created on first sight by the principal interceptor. {@code testuser} is left to
 * AccountServiceTest, which deletes its account before each test.
 */
public final class TestUsers {

    public static final String ALICE = "alice";
    public static final String BOB = "bob";
    public static final String CAROL = "carol";
    public static final String DAVE = "dave";
    public static final String ERIN = "erin";

    static final Duration TOKEN_REUSE = Duration.ofMinutes(10);

    private record Cached(String token, Instant fetched) {
    }

    private static final Map<String, Cached> TOKENS = new ConcurrentHashMap<>();
    private static final Map<String, UUID> ACCOUNTS = new ConcurrentHashMap<>();

    private TestUsers() {
    }

    /** The Mac client's client id; tokens from it carry no wt_auth_method and read as password. */
    public static final String MAC = "wiretuner-mac";
    /** The test client whose tokens claim a workspace SSO sign-in ({@code sso:acme}). */
    public static final String SSO = "wiretuner-test-sso";

    public static String token(String user) {
        return token(user, MAC);
    }

    public static String token(String user, String client) {
        String key = user + "/" + client;
        Cached cached = TOKENS.get(key);
        if (cached == null || cached.fetched().plus(TOKEN_REUSE).isBefore(Instant.now())) {
            cached = new Cached(new KeycloakTestClient().getAccessToken(user, "testpass", client, null), Instant.now());
            TOKENS.put(key, cached);
        }
        return cached.token();
    }

    /** The stub, calling as {@code user} with a token from {@code client}. */
    public static <S extends AbstractStub<S>> S viaClient(S stub, String user, String client) {
        Metadata headers = new Metadata();
        headers.put(GrpcMetadata.AUTHORIZATION, "Bearer " + token(user, client));
        return stub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers));
    }

    public static Metadata headers(String user, UUID device) {
        Metadata headers = new Metadata();
        headers.put(GrpcMetadata.AUTHORIZATION, "Bearer " + token(user));
        if (device != null) {
            headers.put(GrpcMetadata.WT_DEVICE, device.toString());
        }
        return headers;
    }

    /** The stub, calling as {@code user} without a device. */
    public static <S extends AbstractStub<S>> S as(S stub, String user) {
        return as(stub, user, null);
    }

    /** The stub, calling as {@code user} from {@code device}. */
    public static <S extends AbstractStub<S>> S as(S stub, String user, UUID device) {
        return stub.withInterceptors(MetadataUtils.newAttachHeadersInterceptor(headers(user, device)));
    }

    public static UUID accountId(AccountServiceGrpc.AccountServiceBlockingStub account, String user) {
        return ACCOUNTS.computeIfAbsent(user,
                u -> UUID.fromString(as(account, u).me(MeRequest.getDefaultInstance()).getAccount().getId()));
    }

    public static String email(String user) {
        return user + "@wiretuner.local";
    }
}
