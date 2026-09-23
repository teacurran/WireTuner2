package com.villagecompute.wiretuner.api.keycloak;

import java.security.GeneralSecurityException;
import java.security.KeyFactory;
import java.security.PrivateKey;
import java.security.spec.PKCS8EncodedKeySpec;
import java.time.Duration;
import java.time.Instant;
import java.util.Base64;

import org.jose4j.jws.AlgorithmIdentifiers;
import org.jose4j.jws.JsonWebSignature;
import org.jose4j.jwt.JwtClaims;
import org.jose4j.jwt.NumericDate;
import org.jose4j.lang.JoseException;

/**
 * The Sign in with Apple client secret (docs/spec/security.adoc, Accounts; D-064): an ES256 JWT signed
 * with the developer team's {@code .p8} key, {@code kid} the key's id, issued by the team, for the
 * Services ID as subject, with Apple as audience, valid for at most six months (Apple refuses more
 * than 15,777,000 seconds).
 */
public final class AppleClientSecret {

    static final String AUDIENCE = "https://appleid.apple.com";

    /** Apple's upper bound on a client secret's lifetime. */
    public static final Duration MAX_LIFETIME = Duration.ofSeconds(15_777_000);

    private AppleClientSecret() {
    }

    /** What the secret is signed for and with. */
    public record Signer(String teamId, String keyId, String clientId, String privateKeyPem) {
    }

    /**
     * The compact JWT valid from {@code now} for {@code lifetime}, capped at {@link #MAX_LIFETIME}.
     * A key that is not a PKCS#8 EC P-256 key is {@link IllegalArgumentException}.
     */
    public static String sign(Signer signer, Instant now, Duration lifetime) {
        Duration valid = lifetime.compareTo(MAX_LIFETIME) > 0 ? MAX_LIFETIME : lifetime;
        JwtClaims claims = new JwtClaims();
        claims.setIssuer(signer.teamId());
        claims.setIssuedAt(NumericDate.fromSeconds(now.getEpochSecond()));
        claims.setExpirationTime(NumericDate.fromSeconds(now.plus(valid).getEpochSecond()));
        claims.setAudience(AUDIENCE);
        claims.setSubject(signer.clientId());
        JsonWebSignature jws = new JsonWebSignature();
        jws.setPayload(claims.toJson());
        jws.setKeyIdHeaderValue(signer.keyId());
        jws.setAlgorithmHeaderValue(AlgorithmIdentifiers.ECDSA_USING_P256_CURVE_AND_SHA256);
        try {
            jws.setKey(privateKey(signer.privateKeyPem()));
            return jws.getCompactSerialization();
        } catch (GeneralSecurityException | JoseException | IllegalArgumentException e) {
            throw new IllegalArgumentException("the Apple key is not a PKCS#8 EC P-256 private key", e);
        }
    }

    /** A PKCS#8 PEM ({@code -----BEGIN PRIVATE KEY-----}, as Apple's {@code .p8} is) to an EC private key. */
    static PrivateKey privateKey(String pem) throws GeneralSecurityException {
        String body = pem.replaceAll("-----(BEGIN|END) PRIVATE KEY-----", "").replaceAll("\\s", "");
        return KeyFactory.getInstance("EC").generatePrivate(new PKCS8EncodedKeySpec(Base64.getDecoder().decode(body)));
    }
}
