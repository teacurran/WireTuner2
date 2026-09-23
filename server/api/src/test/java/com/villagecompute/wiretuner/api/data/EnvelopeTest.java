package com.villagecompute.wiretuner.api.data;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.util.Base64;

import javax.crypto.Cipher;

import org.junit.jupiter.api.Test;

/**
 * DATA-005: envelope encryption. A secret round-trips; its ciphertext is bound to its row (another
 * row's associated data does not open it) and to its bytes (any flipped bit fails); rotation re-wraps
 * the data key under the new master key without touching the ciphertext; unknown keys and malformed
 * configuration are refused.
 */
class EnvelopeTest {

    static String key(String text) {
        return Base64.getEncoder().encodeToString(text.getBytes(StandardCharsets.UTF_8));
    }

    static final String K1 = "k1:" + key("first-master-key-for-tests-32-b!");
    static final String K2 = "k2:" + key("other-master-key-for-tests-32-b!");

    @Test
    void roundTripsAndBindsToTheRow() {
        Envelope envelope = Envelope.parse(K1);
        byte[] aad = DataScope.team(java.util.UUID.randomUUID()).aad("github");
        Envelope.Sealed sealed = envelope.seal("s3cret".getBytes(StandardCharsets.UTF_8), aad);
        assertThat(sealed.keyId()).isEqualTo("k1");
        assertThat(new String(sealed.ciphertext(), StandardCharsets.ISO_8859_1)).doesNotContain("s3cret");
        assertThat(new String(envelope.open(sealed, aad), StandardCharsets.UTF_8)).isEqualTo("s3cret");
        assertThatThrownBy(() -> envelope.open(sealed, "other".getBytes(StandardCharsets.UTF_8)))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("open");
        byte[] tampered = sealed.ciphertext().clone();
        tampered[tampered.length - 1] ^= 1;
        assertThatThrownBy(() -> envelope.open(new Envelope.Sealed("k1", sealed.wrappedKey(), tampered), aad))
                .isInstanceOf(IllegalStateException.class);
        byte[] wrapped = sealed.wrappedKey().clone();
        wrapped[20] ^= 1;
        assertThatThrownBy(() -> envelope.open(new Envelope.Sealed("k1", wrapped, sealed.ciphertext()), aad))
                .isInstanceOf(IllegalStateException.class);
    }

    @Test
    void rotationRewrapsTheDataKeyOnly() {
        byte[] aad = "row".getBytes(StandardCharsets.UTF_8);
        Envelope.Sealed old = Envelope.parse(K1).seal("value".getBytes(StandardCharsets.UTF_8), aad);
        Envelope rotated = Envelope.parse(K2 + ", " + K1 + ",");
        assertThat(rotated.currentKeyId()).isEqualTo("k2");
        assertThat(new String(rotated.open(old, aad), StandardCharsets.UTF_8)).isEqualTo("value");
        Envelope.Sealed rewrapped = rotated.rewrap(old);
        assertThat(rewrapped.keyId()).isEqualTo("k2");
        assertThat(rewrapped.ciphertext()).isEqualTo(old.ciphertext());
        assertThat(rewrapped.wrappedKey()).isNotEqualTo(old.wrappedKey());
        assertThat(new String(Envelope.parse(K2).open(rewrapped, aad), StandardCharsets.UTF_8)).isEqualTo("value");
        assertThatThrownBy(() -> Envelope.parse(K2).open(old, aad)).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("master key k1 is not configured");
    }

    @Test
    void noKeyConfiguredRefusesEverything() {
        Envelope none = Envelope.parse("");
        assertThat(none.currentKeyId()).isNull();
        assertThatThrownBy(() -> none.seal(new byte[1], new byte[0])).isInstanceOf(IllegalStateException.class)
                .hasMessageContaining("not configured");
        assertThatThrownBy(() -> none.derive("x")).isInstanceOf(IllegalStateException.class);
    }

    @Test
    void refusesMalformedConfiguration() {
        assertThatThrownBy(() -> Envelope.parse("nocolon")).isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> Envelope.parse(":" + key("first-master-key-for-tests-32-b!")))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> Envelope.parse("short:" + key("too short"))).isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("32 bytes");
    }

    @Test
    void derivesStablePurposeKeys() {
        Envelope envelope = Envelope.parse(K1);
        assertThat(envelope.derive("a")).isEqualTo(Envelope.parse(K1).derive("a")).isNotEqualTo(envelope.derive("b"))
                .hasSize(32);
    }

    @Test
    void cryptoFailuresNameTheOperation() {
        assertThatThrownBy(() -> Envelope.gcm(Cipher.ENCRYPT_MODE, new byte[5], new byte[0], new byte[1]))
                .isInstanceOf(IllegalStateException.class).hasMessageContaining("envelope seal failed");
        assertThatThrownBy(() -> Envelope.crypto("thing", () -> {
            throw new GeneralSecurityException("boom");
        })).isInstanceOf(IllegalStateException.class).hasMessage("thing failed");
    }
}
