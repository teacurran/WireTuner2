package com.villagecompute.wiretuner.api.auth;

import static org.assertj.core.api.Assertions.assertThat;

import java.util.List;

import org.jose4j.jwt.consumer.ErrorCodeValidator;
import org.jose4j.jwt.consumer.ErrorCodes;
import org.jose4j.jwt.consumer.InvalidJwtException;
import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.grpc.StatusExceptions;

import io.grpc.Status;
import io.grpc.StatusRuntimeException;
import io.quarkus.security.AuthenticationFailedException;
import io.quarkus.security.identity.CurrentIdentityAssociation;
import io.quarkus.security.identity.SecurityIdentity;
import io.quarkus.security.runtime.QuarkusPrincipal;
import io.quarkus.security.runtime.QuarkusSecurityIdentity;
import io.smallrye.mutiny.Uni;

/** The failure half of principal resolution, which never reaches the database. */
class PrincipalsTest {

    @Test
    void anAnonymousIdentityIsUnauthenticated() {
        StatusRuntimeException e = resolveFailure(Uni.createFrom().item(
                QuarkusSecurityIdentity.builder().setAnonymous(true).build()));
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        assertThat(StatusExceptions.reasonOf(e)).isEmpty();
    }

    @Test
    void aNonJwtIdentityIsUnauthenticated() {
        StatusRuntimeException e = resolveFailure(Uni.createFrom().item(
                QuarkusSecurityIdentity.builder().setPrincipal(new QuarkusPrincipal("basic-user")).build()));
        assertThat(e.getStatus().getDescription()).isEqualTo("bearer token is not a JWT");
    }

    @Test
    void anExpiredTokenIsTokenExpired() {
        InvalidJwtException expired = new InvalidJwtException("expired",
                List.of(new ErrorCodeValidator.Error(ErrorCodes.EXPIRED, "expired")), null);
        StatusRuntimeException e = resolveFailure(Uni.createFrom().failure(new AuthenticationFailedException(expired)));
        assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
        assertThat(StatusExceptions.reasonOf(e)).contains("TOKEN_EXPIRED");
    }

    @Test
    void anyOtherRejectionIsPlainUnauthenticated() {
        InvalidJwtException badSignature = new InvalidJwtException("sig",
                List.of(new ErrorCodeValidator.Error(ErrorCodes.SIGNATURE_INVALID, "sig")), null);
        for (Throwable failure : List.of(new AuthenticationFailedException(badSignature),
                new AuthenticationFailedException("no cause"))) {
            StatusRuntimeException e = resolveFailure(Uni.createFrom().failure(failure));
            assertThat(e.getStatus().getCode()).isEqualTo(Status.Code.UNAUTHENTICATED);
            assertThat(StatusExceptions.reasonOf(e)).isEmpty();
        }
    }

    @Test
    void theResultIsMemoisedPerRequest() {
        Principals principals = principals(Uni.createFrom().item(QuarkusSecurityIdentity.builder().setAnonymous(true).build()));
        assertThat(principals.current()).isSameAs(principals.current());
    }

    @Test
    void platformIsTheFirstSegmentOfWtClient() {
        assertThat(Principals.platformOf(null)).isEmpty();
        assertThat(Principals.platformOf("macos")).isEqualTo("macos");
        assertThat(Principals.platformOf("macos/1.2/345")).isEqualTo("macos");
    }

    static StatusRuntimeException resolveFailure(Uni<SecurityIdentity> identity) {
        Principals principals = principals(identity);
        Throwable failure = null;
        try {
            principals.current().await().indefinitely();
        } catch (Throwable t) {
            failure = t;
        }
        assertThat(failure).isInstanceOf(StatusRuntimeException.class);
        return (StatusRuntimeException) failure;
    }

    static Principals principals(Uni<SecurityIdentity> identity) {
        Principals principals = new Principals();
        principals.callMetadata = new CallMetadata();
        principals.identityAssociation = new CurrentIdentityAssociation() {
            @Override
            public void setIdentity(SecurityIdentity ignored) {
                throw new UnsupportedOperationException();
            }

            @Override
            public void setIdentity(Uni<SecurityIdentity> ignored) {
                throw new UnsupportedOperationException();
            }

            @Override
            public SecurityIdentity getIdentity() {
                throw new UnsupportedOperationException();
            }

            @Override
            public Uni<SecurityIdentity> getDeferredIdentity() {
                return identity;
            }
        };
        return principals;
    }
}
