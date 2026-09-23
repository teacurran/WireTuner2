package com.villagecompute.wiretuner.api.data;

import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.GeneralSecurityException;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.Map;

import javax.crypto.Cipher;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

/**
 * Envelope encryption of credential secrets (data-merge.adoc, Secret store; DATA-005). Each secret
 * gets a random 256-bit data key; the secret is sealed with it (AES-256-GCM, a random 96-bit nonce,
 * the row's scope and name as associated data, so a ciphertext cannot be moved to another row), and
 * the data key is wrapped with a master key (AES-256-GCM again). Rotation re-wraps the data key
 * under the new master key and never touches the secret's ciphertext.
 *
 * <p>Master keys come from {@code WT_DATA_MASTER_KEY}: comma-separated {@code id:base64} entries of
 * 32-byte keys, the first being the one new rows are wrapped with and the others kept only to unwrap
 * rows not yet rotated. Sealed bytes are the 12-byte nonce followed by the GCM ciphertext and tag.
 */
public final class Envelope {

    static final String CIPHER = "AES/GCM/NoPadding";
    static final int KEY_BYTES = 32;
    static final int NONCE_BYTES = 12;
    static final int TAG_BITS = 128;
    static final byte[] WRAP_AAD = "wt-data-key".getBytes(StandardCharsets.UTF_8);

    private static final SecureRandom RANDOM = new SecureRandom();

    /** A sealed secret: the master key id, the wrapped data key, and the secret's ciphertext. */
    public record Sealed(String keyId, byte[] wrappedKey, byte[] ciphertext) {
    }

    private final String currentId;
    private final Map<String, byte[]> keys;

    Envelope(String currentId, Map<String, byte[]> keys) {
        this.currentId = currentId;
        this.keys = keys;
    }

    /** Parses the {@code WT_DATA_MASTER_KEY} value; an empty value leaves the store unusable (every seal fails). */
    public static Envelope parse(String config) {
        Map<String, byte[]> keys = new LinkedHashMap<>();
        String first = null;
        for (String entry : config.split(",")) {
            String trimmed = entry.strip();
            if (trimmed.isEmpty()) {
                continue;
            }
            int colon = trimmed.indexOf(':');
            if (colon <= 0) {
                throw new IllegalArgumentException("WT_DATA_MASTER_KEY entries are id:base64");
            }
            byte[] key = java.util.Base64.getDecoder().decode(trimmed.substring(colon + 1));
            if (key.length != KEY_BYTES) {
                throw new IllegalArgumentException("master key " + trimmed.substring(0, colon) + " is not 32 bytes");
            }
            String id = trimmed.substring(0, colon);
            keys.put(id, key);
            if (first == null) {
                first = id;
            }
        }
        return new Envelope(first, keys);
    }

    /** The id new rows are wrapped with; null when no key is configured. */
    public String currentKeyId() {
        return currentId;
    }

    /** Seals a secret for the row identified by {@code aad}. */
    public Sealed seal(byte[] secret, byte[] aad) {
        byte[] dataKey = new byte[KEY_BYTES];
        RANDOM.nextBytes(dataKey);
        try {
            return new Sealed(currentId, gcm(Cipher.ENCRYPT_MODE, master(currentId), WRAP_AAD, dataKey),
                    gcm(Cipher.ENCRYPT_MODE, dataKey, aad, secret));
        } finally {
            Arrays.fill(dataKey, (byte) 0);
        }
    }

    /** Opens a sealed secret; fails when the key is unknown or the bytes or associated data were altered. */
    public byte[] open(Sealed sealed, byte[] aad) {
        byte[] dataKey = gcm(Cipher.DECRYPT_MODE, master(sealed.keyId()), WRAP_AAD, sealed.wrappedKey());
        try {
            return gcm(Cipher.DECRYPT_MODE, dataKey, aad, sealed.ciphertext());
        } finally {
            Arrays.fill(dataKey, (byte) 0);
        }
    }

    /** The same secret with its data key re-wrapped under the current master key. */
    public Sealed rewrap(Sealed sealed) {
        byte[] dataKey = gcm(Cipher.DECRYPT_MODE, master(sealed.keyId()), WRAP_AAD, sealed.wrappedKey());
        try {
            return new Sealed(currentId, gcm(Cipher.ENCRYPT_MODE, master(currentId), WRAP_AAD, dataKey), sealed.ciphertext());
        } finally {
            Arrays.fill(dataKey, (byte) 0);
        }
    }

    private byte[] master(String id) {
        byte[] key = id == null ? null : keys.get(id);
        if (key == null) {
            throw new IllegalStateException("master key " + id + " is not configured (WT_DATA_MASTER_KEY)");
        }
        return key;
    }

    /** Derives a purpose-specific key from the current master key (HMAC-SHA256 of the purpose). */
    public byte[] derive(String purpose) {
        byte[] key = master(currentId);
        return crypto("key derivation", () -> {
            javax.crypto.Mac mac = javax.crypto.Mac.getInstance("HmacSHA256");
            mac.init(new SecretKeySpec(key, "HmacSHA256"));
            return mac.doFinal(purpose.getBytes(StandardCharsets.UTF_8));
        });
    }

    static byte[] gcm(int mode, byte[] key, byte[] aad, byte[] input) {
        boolean seal = mode == Cipher.ENCRYPT_MODE;
        return crypto(seal ? "envelope seal" : "envelope open", () -> {
            Cipher cipher = Cipher.getInstance(CIPHER);
            if (seal) {
                byte[] nonce = new byte[NONCE_BYTES];
                RANDOM.nextBytes(nonce);
                cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_BITS, nonce));
                cipher.updateAAD(aad);
                byte[] sealed = cipher.doFinal(input);
                return ByteBuffer.allocate(NONCE_BYTES + sealed.length).put(nonce).put(sealed).array();
            }
            cipher.init(mode, new SecretKeySpec(key, "AES"), new GCMParameterSpec(TAG_BITS, input, 0, NONCE_BYTES));
            cipher.updateAAD(aad);
            return cipher.doFinal(input, NONCE_BYTES, input.length - NONCE_BYTES);
        });
    }

    /** A JCA operation. */
    interface CryptoOp<T> {
        T run() throws GeneralSecurityException;
    }

    /** Runs a JCA operation; its checked failure becomes an {@link IllegalStateException} naming {@code what}. */
    static <T> T crypto(String what, CryptoOp<T> op) {
        try {
            return op.run();
        } catch (GeneralSecurityException e) {
            throw new IllegalStateException(what + " failed", e);
        }
    }
}
