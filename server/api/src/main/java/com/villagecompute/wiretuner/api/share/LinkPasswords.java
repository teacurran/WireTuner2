package com.villagecompute.wiretuner.api.share;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Base64;

import org.bouncycastle.crypto.generators.Argon2BytesGenerator;
import org.bouncycastle.crypto.params.Argon2Parameters;

import com.villagecompute.wiretuner.api.grpc.CallerContext;

import io.smallrye.mutiny.Uni;
import io.smallrye.mutiny.infrastructure.Infrastructure;

/**
 * Share-link passwords (sharing.adoc, Share links): stored as an argon2id PHC string
 * ({@code $argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>}, OWASP's minimum parameters, 16-byte salt,
 * 32-byte hash), never returned. Hashing takes tens of milliseconds and 19 MiB, so it runs on a
 * worker thread and the result is re-emitted on the caller's context.
 */
final class LinkPasswords {

    static final int MEMORY_KIB = 19_456;
    static final int ITERATIONS = 2;
    static final int PARALLELISM = 1;
    static final int SALT_BYTES = 16;
    static final int HASH_BYTES = 32;

    private static final SecureRandom RANDOM = new SecureRandom();
    private static final Base64.Encoder B64 = Base64.getEncoder().withoutPadding();
    private static final Base64.Decoder B64D = Base64.getDecoder();

    private LinkPasswords() {
    }

    /** The PHC string for a password, computed off the event loop. */
    static Uni<String> hash(String password) {
        return offload(() -> hashNow(password));
    }

    /** Whether the password matches the PHC string, computed off the event loop. */
    static Uni<Boolean> verify(String password, String phc) {
        return offload(() -> verifyNow(password, phc));
    }

    static String hashNow(String password) {
        byte[] salt = new byte[SALT_BYTES];
        RANDOM.nextBytes(salt);
        byte[] hash = derive(password, salt, MEMORY_KIB, ITERATIONS, PARALLELISM);
        return "$argon2id$v=19$m=" + MEMORY_KIB + ",t=" + ITERATIONS + ",p=" + PARALLELISM + "$" + B64.encodeToString(salt)
                + "$" + B64.encodeToString(hash);
    }

    /** Recomputes with the string's own parameters and salt, and compares in constant time. */
    static boolean verifyNow(String password, String phc) {
        String[] parts = phc.split("\\$");
        String[] params = parts[3].split(",");
        byte[] salt = B64D.decode(parts[4]);
        byte[] expected = B64D.decode(parts[5]);
        byte[] actual = derive(password, salt, value(params[0]), value(params[1]), value(params[2]));
        return MessageDigest.isEqual(expected, actual);
    }

    private static int value(String param) {
        return Integer.parseInt(param.substring(param.indexOf('=') + 1));
    }

    private static byte[] derive(String password, byte[] salt, int memoryKib, int iterations, int parallelism) {
        Argon2BytesGenerator generator = new Argon2BytesGenerator();
        generator.init(new Argon2Parameters.Builder(Argon2Parameters.ARGON2_id)
                .withVersion(Argon2Parameters.ARGON2_VERSION_13)
                .withMemoryAsKB(memoryKib)
                .withIterations(iterations)
                .withParallelism(parallelism)
                .withSalt(salt)
                .build());
        byte[] out = new byte[HASH_BYTES];
        generator.generateBytes(password.getBytes(StandardCharsets.UTF_8), out);
        return out;
    }

    private static <T> Uni<T> offload(java.util.function.Supplier<T> work) {
        return Uni.createFrom().item(work)
                .runSubscriptionOn(Infrastructure.getDefaultWorkerPool())
                .emitOn(CallerContext.executor());
    }
}
