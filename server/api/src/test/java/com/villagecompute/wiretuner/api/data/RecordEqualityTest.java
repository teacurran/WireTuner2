package com.villagecompute.wiretuner.api.data;

import static com.villagecompute.wiretuner.api.RecordContent.contentProblems;
import static org.assertj.core.api.Assertions.assertThat;

import java.net.URI;
import java.time.Duration;
import java.util.List;
import java.util.Map;
import java.util.UUID;

import org.junit.jupiter.api.Test;

import com.villagecompute.wiretuner.api.history.Snapshots;
import com.villagecompute.wiretuner.api.persistence.TeamFontRepository;

/**
 * Records with a byte-array component compare and hash by the array's content, not its identity, and
 * print it without leaking it (Sonar java:S6218): two records built from equal bytes are equal, and
 * changing any one component makes them differ.
 */
class RecordEqualityTest {

    static final URI URL = URI.create("https://example.com/a");
    static final URI OTHER_URL = URI.create("https://example.com/b");
    static final Duration SECOND = Duration.ofSeconds(1);

    static byte[] bytes(int... values) {
        byte[] out = new byte[values.length];
        for (int i = 0; i < values.length; i++) {
            out[i] = (byte) values[i];
        }
        return out;
    }

    @Test
    void cidrsCompareTheirPrefix() {
        assertThat(contentProblems(() -> new AddressPolicy.Cidr(bytes(10, 0, 0, 0), 8), "prefix=0a000000",
                new AddressPolicy.Cidr(bytes(11, 0, 0, 0), 8),
                new AddressPolicy.Cidr(bytes(10, 0, 0, 0), 16))).isEmpty();
    }

    @Test
    void requestsCompareTheirBodyAndPrintNoCredential() {
        Map<String, String> headers = Map.of("authorization", "Bearer secret-token");
        assertThat(contentProblems(() -> new Egress.Request("POST", URL, headers, bytes(1, 2), SECOND, 10), "body=2 bytes",
                new Egress.Request("PUT", URL, headers, bytes(1, 2), SECOND, 10),
                new Egress.Request("POST", OTHER_URL, headers, bytes(1, 2), SECOND, 10),
                new Egress.Request("POST", URL, Map.of(), bytes(1, 2), SECOND, 10),
                new Egress.Request("POST", URL, headers, bytes(1, 3), SECOND, 10),
                new Egress.Request("POST", URL, headers, bytes(1, 2), Duration.ofSeconds(2), 10),
                new Egress.Request("POST", URL, headers, bytes(1, 2), SECOND, 11))).isEmpty();
        Egress.Request get = new Egress.Request("GET", URL, headers, null, SECOND, 10);
        assertThat(get.toString()).contains("headers=[authorization]", "body=null").doesNotContain("secret-token");
    }

    @Test
    void repliesCompareTheirBody() {
        List<Map.Entry<String, String>> headers = List.of(Map.entry("set-cookie", "session=secret"));
        assertThat(contentProblems(() -> new Egress.Reply(200, headers, bytes(4, 5, 6), URL), "body=3 bytes",
                new Egress.Reply(404, headers, bytes(4, 5, 6), URL),
                new Egress.Reply(200, List.of(), bytes(4, 5, 6), URL),
                new Egress.Reply(200, headers, bytes(4, 5), URL),
                new Egress.Reply(200, headers, bytes(4, 5, 6), OTHER_URL))).isEmpty();
        assertThat(new Egress.Reply(200, headers, bytes(), URL).toString()).contains("headers=[set-cookie]")
                .doesNotContain("secret");
    }

    @Test
    void sealedSecretsCompareTheirBytesAndPrintOnlyLengths() {
        assertThat(contentProblems(() -> new Envelope.Sealed("k1", bytes(1, 2), bytes(3, 4, 5)), "ciphertext=3 bytes",
                new Envelope.Sealed("k2", bytes(1, 2), bytes(3, 4, 5)),
                new Envelope.Sealed("k1", bytes(1, 9), bytes(3, 4, 5)),
                new Envelope.Sealed("k1", bytes(1, 2), bytes(3, 4, 9)))).isEmpty();
        assertThat(new Envelope.Sealed("k1", bytes(0x7f), bytes(0x7e))).hasToString(
                "Sealed[keyId=k1, wrappedKey=1 bytes, ciphertext=1 bytes]");
    }

    @Test
    void encodedSnapshotsCompareTheirObject() {
        assertThat(contentProblems(() -> new Snapshots.Encoded("key", bytes(1, 2, 3, 4), "ab", 10, 2), "object=4 bytes",
                new Snapshots.Encoded("other", bytes(1, 2, 3, 4), "ab", 10, 2),
                new Snapshots.Encoded("key", bytes(1, 2, 3), "ab", 10, 2),
                new Snapshots.Encoded("key", bytes(1, 2, 3, 4), "cd", 10, 2),
                new Snapshots.Encoded("key", bytes(1, 2, 3, 4), "ab", 11, 2),
                new Snapshots.Encoded("key", bytes(1, 2, 3, 4), "ab", 10, 3))).isEmpty();
    }

    @Test
    void teamFontsCompareTheirFaces() {
        UUID team = UUID.randomUUID();
        UUID uploader = UUID.randomUUID();
        UUID other = UUID.randomUUID();
        assertThat(contentProblems(() -> new TeamFontRepository.Font("sha", team, "a.ttf", "font/ttf", bytes(1), uploader, 5, 6, "s"),
                "faces=1 bytes",
                new TeamFontRepository.Font("sha2", team, "a.ttf", "font/ttf", bytes(1), uploader, 5, 6, "s"),
                new TeamFontRepository.Font("sha", other, "a.ttf", "font/ttf", bytes(1), uploader, 5, 6, "s"),
                new TeamFontRepository.Font("sha", team, "b.ttf", "font/ttf", bytes(1), uploader, 5, 6, "s"),
                new TeamFontRepository.Font("sha", team, "a.ttf", "font/otf", bytes(1), uploader, 5, 6, "s"),
                new TeamFontRepository.Font("sha", team, "a.ttf", "font/ttf", bytes(2), uploader, 5, 6, "s"),
                new TeamFontRepository.Font("sha", team, "a.ttf", "font/ttf", bytes(1), other, 5, 6, "s"),
                new TeamFontRepository.Font("sha", team, "a.ttf", "font/ttf", bytes(1), uploader, 7, 6, "s"),
                new TeamFontRepository.Font("sha", team, "a.ttf", "font/ttf", bytes(1), uploader, 5, 7, "s"),
                new TeamFontRepository.Font("sha", team, "a.ttf", "font/ttf", bytes(1), uploader, 5, 6, "t"))).isEmpty();
    }
}
